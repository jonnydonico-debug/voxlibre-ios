import Foundation

/// Minimal Claude Messages API client over raw HTTPS (there is no official Swift SDK).
/// Content blocks are kept as JSON dictionaries so every block type the API returns —
/// text, tool_use, thinking, fallback, … — can be passed back unchanged on the next turn.
struct Claude {
    static let model = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let apiKey: String

    enum Failure: LocalizedError {
        case noKey, http(Int, String), badResponse(String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "Add your Claude API key in Settings › AI."
            case .http(let code, let msg): return "Claude API error \(code): \(msg)"
            case .badResponse(let m): return "Unexpected response from Claude: \(m)"
            }
        }
    }

    /// The final assembled message: `content` blocks plus `stop_reason`.
    struct Message {
        var content: [[String: Any]]
        var stopReason: String
        var text: String {
            content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        }
        var toolUses: [[String: Any]] { content.filter { $0["type"] as? String == "tool_use" } }
    }

    /// Base request body. Server-side refusal fallback is on ("default" routing), so if
    /// a safety classifier declines, the API re-runs the turn on a fallback model.
    static func body(system: [[String: Any]], messages: [[String: Any]], tools: [[String: Any]] = [],
                     effort: String, maxTokens: Int = 64000) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": messages,
            "output_config": ["effort": effort],
            "fallbacks": "default",
            "cache_control": ["type": "ephemeral"],
        ]
        if !tools.isEmpty { b["tools"] = tools }
        return b
    }

    /// Streams one request. `onText` gets text deltas as they arrive (for live display and
    /// speech). Returns the complete message once the stream ends.
    func stream(_ body: [String: Any], onText: ((String) -> Void)? = nil) async throws -> Message {
        guard !apiKey.isEmpty else { throw Failure.noKey }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 20_000 { break } }
            throw Failure.http(status, Self.errorMessage(raw))
        }

        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var stopReason = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let ev = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            switch type {
            case "content_block_start":
                if let i = ev["index"] as? Int, let cb = ev["content_block"] as? [String: Any] {
                    blocks[i] = cb
                    if let t = cb["text"] as? String, !t.isEmpty, cb["type"] as? String == "text" { onText?(t) }
                }
            case "content_block_delta":
                guard let i = ev["index"] as? Int, let d = ev["delta"] as? [String: Any],
                      var cb = blocks[i] else { continue }
                switch d["type"] as? String {
                case "text_delta":
                    let t = d["text"] as? String ?? ""
                    cb["text"] = (cb["text"] as? String ?? "") + t
                    onText?(t)
                case "input_json_delta":
                    partialJSON[i, default: ""] += d["partial_json"] as? String ?? ""
                case "thinking_delta":
                    cb["thinking"] = (cb["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
                case "signature_delta":
                    cb["signature"] = d["signature"] as? String ?? ""
                case "citations_delta":
                    if let c = d["citation"] { cb["citations"] = (cb["citations"] as? [Any] ?? []) + [c] }
                default:
                    break
                }
                blocks[i] = cb
            case "message_delta":
                if let d = ev["delta"] as? [String: Any], let s = d["stop_reason"] as? String { stopReason = s }
            case "error":
                let e = ev["error"] as? [String: Any]
                throw Failure.http(0, e?["message"] as? String ?? "stream error")
            default:
                break
            }
        }
        // Tool inputs arrive as partial JSON; parse once complete. An unparsable input is
        // kept as an empty object and flagged so the caller can return an error result.
        for (i, js) in partialJSON {
            guard var cb = blocks[i] else { continue }
            if js.isEmpty {
                cb["input"] = cb["input"] ?? [String: Any]()
            } else if let obj = (try? JSONSerialization.jsonObject(with: Data(js.utf8))) as? [String: Any] {
                cb["input"] = obj
            } else {
                cb["input"] = [String: Any]()
                cb["_invalid_input"] = true
            }
            blocks[i] = cb
        }
        let content = blocks.keys.sorted().compactMap { blocks[$0] }
        return Message(content: content, stopReason: stopReason)
    }

    static func errorMessage(_ raw: Data) -> String {
        if let j = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
           let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return String(decoding: raw.prefix(300), as: UTF8.self)
    }

    /// Strip client-only markers before sending blocks back to the API.
    static func clean(_ blocks: [[String: Any]]) -> [[String: Any]] {
        blocks.map { var b = $0; b.removeValue(forKey: "_invalid_input"); return b }
    }
}

/// Optional bridge to a house agent (a smart-home assistant you run yourself).
/// Protocol: `POST <base>/api/ring/ask`, `Authorization: Bearer <token>`,
/// body `{"message": "..."}` → `{"answer": "..."}`. See README › House agent.
struct HouseAgentClient {
    let baseURL: String
    let token: String

    var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    func ask(_ message: String) async throws -> String {
        guard isConfigured, let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/api/ring/ask") else {
            throw Claude.Failure.badResponse("The house agent isn't set up — add its address and token in Settings › AI & voice.")
        }
        // Never send the token over plain HTTP.
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw Claude.Failure.badResponse("The house agent address must start with https://")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["message": message])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            throw Claude.Failure.badResponse("The house agent returned \(status): " + ((j?["error"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)))
        }
        return (j?["answer"] as? String) ?? ""
    }
}
