import Foundation

/// Natural-sounding speech from OpenAI's text-to-speech API (gpt-4o-mini-tts), using the
/// user's own key. Only the reply text is sent; it comes back as an MP3.
struct OpenAITTS {
    static let model = "gpt-4o-mini-tts"
    static let voices = ["coral", "marin", "cedar", "sage", "nova", "shimmer", "alloy",
                         "ash", "ballad", "echo", "fable", "onyx", "verse"]
    static let defaultStyle = """
        Warm, relaxed and conversational, like a friend talking quietly in your ear. \
        Natural pace with small pauses; not a newsreader, not overly cheerful.
        """

    let apiKey: String
    let voice: String
    let style: String

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func speech(_ text: String) async throws -> Data {
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": Self.model, "voice": voice, "input": text, "response_format": "mp3"]
        let s = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { body["instructions"] = s }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            throw Failure(message: "OpenAI voice (\(code)): \(msg ?? "request failed")")
        }
        return data
    }
}
