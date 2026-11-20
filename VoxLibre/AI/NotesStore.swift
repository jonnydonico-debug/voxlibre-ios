import Foundation

// MARK: - Models

struct Segment: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
    var speaker: String?   // label, e.g. "S1"
}

struct Speaker: Codable, Hashable {
    var label: String
    var name: String
    var isWearer: Bool
    var evidence: String
}

struct ActionItem: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    var owner: String
    var due: String
    var done: Bool = false
    var houseReply: String?
}

struct Analysis: Codable {
    var title: String
    var kind: String
    var summary: String
    var speakers: [Speaker]
    var insights: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var topics: [String]
    var rememberedIds: [String]
}

/// Everything the AI knows about one recording (transcript + analysis).
struct RecordingNotes: Codable {
    var id: String
    var segments: [Segment]?
    var analysis: Analysis?
    var error: String?
    var transcribedAt: Date?
    var analyzedAt: Date?

    func speakerName(_ label: String?) -> String {
        guard let label else { return "" }
        return analysis?.speakers.first { $0.label == label }?.name ?? label
    }

    /// Speaker-labelled transcript text, merging consecutive segments by the same speaker.
    func transcriptText(maxChars: Int = .max) -> String {
        guard let segs = segments, !segs.isEmpty else { return "" }
        var lines: [String] = []
        var cur: (String?, String, Double)? = nil
        for s in segs {
            if let c = cur, c.0 == s.speaker {
                cur = (c.0, c.1 + " " + s.text, c.2)
            } else {
                if let c = cur { lines.append(Self.line(c, self)) }
                cur = (s.speaker, s.text, s.start)
            }
        }
        if let c = cur { lines.append(Self.line(c, self)) }
        let all = lines.joined(separator: "\n")
        return all.count > maxChars ? String(all.prefix(maxChars)) + "\n[…transcript truncated]" : all
    }

    private static func line(_ c: (String?, String, Double), _ n: RecordingNotes) -> String {
        let who = n.speakerName(c.0)
        return "[\(fmtTime(c.2))]" + (who.isEmpty ? " " : " \(who): ") + c.1
    }
}

func fmtTime(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Store + pipeline

/// Per-recording notes on disk (Application Support/VoxLibre/notes/<id>.json) and the
/// transcribe → analyse pipeline. Runs one recording at a time.
final class NotesStore: ObservableObject {
    enum Stage: Equatable { case queued, decoding, transcribing, analyzing }

    @Published private(set) var notes: [String: RecordingNotes] = [:]
    @Published private(set) var stage: [String: Stage] = [:]

    private let memory: MemoryStore
    private let settings: AISettings
    var log: (String) -> Void = { _ in }
    private var queue: [(id: String, analyze: Bool)] = []
    private var running = false

    private let dir: URL = {
        let u = MemoryStore.dir.appendingPathComponent("notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    init(memory: MemoryStore, settings: AISettings) {
        self.memory = memory
        self.settings = settings
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let n = try? JSONDecoder.iso.decode(RecordingNotes.self, from: d) {
                notes[n.id] = n
            }
        }
    }

    func save(_ n: RecordingNotes) {
        notes[n.id] = n
        if let d = try? JSONEncoder.iso.encode(n) {
            try? d.write(to: dir.appendingPathComponent("\(n.id).json"), options: .atomic)
        }
    }

    func delete(_ id: String) {
        notes[id] = nil
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    // MARK: pipeline
    /// Transcribe (if needed) and, when `analyze` is on and a Claude key is set, analyse.
    func process(_ id: String, analyze: Bool = true, force: Bool = false) {
        guard stage[id] == nil else { return }
        if force {
            var n = notes[id] ?? RecordingNotes(id: id)
            n.error = nil
            n.analysis = nil
            n.analyzedAt = nil
            save(n)
        }
        stage[id] = .queued
        queue.append((id, analyze))
        pump()
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let job = queue.removeFirst()
        Task { @MainActor in
            await self.run(job.id, analyze: job.analyze)
            self.stage[job.id] = nil
            self.running = false
            self.pump()
        }
    }

    @MainActor
    private func run(_ id: String, analyze: Bool) async {
        var n = notes[id] ?? RecordingNotes(id: id)
        n.error = nil
        do {
            if n.segments == nil {
                stage[id] = .decoding
                let wav = try await Self.ensureWav(id)
                stage[id] = .transcribing
                log("transcribing \(id)…")
                let segs = try await Transcriber.transcribe(wav)
                n.segments = segs
                n.transcribedAt = Date()
                save(n)
                log("transcribed \(id): \(segs.count) segments")
            }
            if analyze, n.analysis == nil, settings.hasClaude {
                if n.segments?.isEmpty ?? true {
                    n.error = "No speech found in this recording."
                } else {
                    stage[id] = .analyzing
                    log("analysing \(id)…")
                    n = try await self.analyze(n)
                    log("analysed \(id): \(n.analysis?.title ?? "")")
                }
            }
        } catch {
            n.error = error.localizedDescription
            log("AI pipeline failed for \(id): \(error.localizedDescription)")
        }
        save(n)
    }

    /// Decode the ring's Opus file to WAV if that hasn't been done yet.
    static func ensureWav(_ id: String) async throws -> URL {
        let docs = RingEngine.docs
        let wav = docs.appendingPathComponent("amsg_\(id)_mono.wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        let src = docs.appendingPathComponent("amsg_\(id)_mono.opus")
        return try await Task.detached(priority: .userInitiated) {
            let pcm = try OpusAudio.decode(try Data(contentsOf: src))
            try OpusAudio.writeWav(pcm, to: wav)
            return wav
        }.value
    }

    // MARK: analysis (Claude)
    private static let analysisSystem = """
    You analyse recordings made with the user's Vocci smart ring. The ring is worn on the user's hand, \
    so the user (the wearer) is usually the closest and most frequent speaker. Transcripts come from \
    on-device speech recognition: they can contain recognition mistakes and do not say who is speaking.

    Fill in every field of the JSON schema:
    - title: 3-8 words naming what this recording is about.
    - kind: one of meeting, conversation, phone call, voice note, lecture, other.
    - summary: 2-5 plain sentences.
    - speakers: the distinct people who speak. Label them S1, S2, ... with S1 = the wearer if they speak. \
    Give a real name only when the recording reveals it (someone is addressed by name, introductions) or a \
    person in memory clearly matches; otherwise a short description such as "Colleague" or "Speaker 2". \
    is_wearer marks the wearer. evidence: one short phrase saying why.
    - segment_speakers: for every numbered segment, the label of who most likely said it. Use turn-taking \
    cues (questions and answers, "I"/"you", names) and give your best guess. A voice memo with one speaker \
    uses S1 throughout.
    - insights: things worth the user's attention that the summary doesn't already say (concerns, \
    opportunities, tone, open questions). 0-6 items.
    - decisions: decisions that were made. Can be empty.
    - action_items: concrete tasks someone committed to or was asked to do. owner = the person's name or \
    "" if unclear; due = the deadline as stated or "".
    - memories: durable facts worth remembering beyond this recording (people and their roles or \
    relationships, preferences, project details, important dates). Skip anything already in memory, small \
    talk, and sensitive details such as health, finances or passwords. 0-5 items; about = the person or \
    topic.
    - topics: 1-5 short tags.
    Write in the language of the transcript.
    """

    private static let analysisSchema: [String: Any] = {
        func obj(_ props: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": props, "required": Array(props.keys), "additionalProperties": false]
        }
        let str: [String: Any] = ["type": "string"]
        let strs: [String: Any] = ["type": "array", "items": str]
        return obj([
            "title": str, "kind": str, "summary": str,
            "speakers": ["type": "array", "items": obj(["label": str, "name": str, "is_wearer": ["type": "boolean"], "evidence": str])],
            "segment_speakers": ["type": "array", "items": obj(["segment": ["type": "integer"], "speaker": str])],
            "insights": strs, "decisions": strs,
            "action_items": ["type": "array", "items": obj(["text": str, "owner": str, "due": str])],
            "memories": ["type": "array", "items": obj(["text": str, "about": str])],
            "topics": strs,
        ])
    }()

    @MainActor
    private func analyze(_ input: RecordingNotes) async throws -> RecordingNotes {
        var n = input
        let segs = n.segments ?? []
        let date = TimeInterval(n.id).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        let length = fmtTime(segs.last?.end ?? 0)
        let who = settings.userName.isEmpty ? "unknown" : settings.userName
        let numbered = segs.enumerated().map { "[\($0.offset)] \(fmtTime($0.element.start)) \($0.element.text)" }
            .joined(separator: "\n")
        let user = """
        Recorded \(df.string(from: date)), length \(length). The wearer's name: \(who).

        What you remember:
        \(memory.promptText)

        Transcript (\(segs.count) segments):
        \(numbered)
        """
        var body = Claude.body(system: [["type": "text", "text": Self.analysisSystem]],
                               messages: [["role": "user", "content": user]], effort: "medium")
        body["output_config"] = ["effort": "medium",
                                 "format": ["type": "json_schema", "schema": Self.analysisSchema]]
        let msg = try await settings.claude.stream(body)
        if msg.stopReason == "refusal" { throw Claude.Failure.badResponse("Claude declined to analyse this recording.") }
        if msg.stopReason == "max_tokens" { throw Claude.Failure.badResponse("The analysis was cut off (recording too long).") }
        guard let j = (try? JSONSerialization.jsonObject(with: Data(msg.text.utf8))) as? [String: Any] else {
            throw Claude.Failure.badResponse("analysis wasn't valid JSON")
        }

        let strs: (String) -> [String] = { (j[$0] as? [String]) ?? [] }
        let speakers = ((j["speakers"] as? [[String: Any]]) ?? []).map {
            Speaker(label: $0["label"] as? String ?? "", name: $0["name"] as? String ?? "",
                    isWearer: $0["is_wearer"] as? Bool ?? false, evidence: $0["evidence"] as? String ?? "")
        }
        for m in (j["segment_speakers"] as? [[String: Any]]) ?? [] {
            if let i = m["segment"] as? Int, i >= 0, i < segs.count, let s = m["speaker"] as? String {
                n.segments?[i].speaker = s
            }
        }
        let items = ((j["action_items"] as? [[String: Any]]) ?? []).map {
            ActionItem(id: UUID().uuidString, text: $0["text"] as? String ?? "",
                       owner: $0["owner"] as? String ?? "", due: $0["due"] as? String ?? "")
        }
        // Previous auto-memories from this recording are replaced on re-analysis.
        memory.removeAll(source: n.id)
        var remembered: [String] = []
        for m in (j["memories"] as? [[String: Any]]) ?? [] {
            if let t = m["text"] as? String,
               let item = memory.add(t, about: m["about"] as? String ?? "", source: n.id) {
                remembered.append(item.id)
            }
        }
        n.analysis = Analysis(title: j["title"] as? String ?? "", kind: j["kind"] as? String ?? "",
                              summary: j["summary"] as? String ?? "", speakers: speakers,
                              insights: strs("insights"), decisions: strs("decisions"),
                              actionItems: items, topics: strs("topics"), rememberedIds: remembered)
        n.analyzedAt = Date()
        return n
    }

    // MARK: edits
    func renameSpeaker(_ id: String, label: String, to name: String) {
        guard var n = notes[id], let i = n.analysis?.speakers.firstIndex(where: { $0.label == label }) else { return }
        n.analysis?.speakers[i].name = name
        save(n)
    }

    func updateActionItem(_ id: String, _ item: ActionItem) {
        guard var n = notes[id], let i = n.analysis?.actionItems.firstIndex(where: { $0.id == item.id }) else { return }
        n.analysis?.actionItems[i] = item
        save(n)
    }

    // MARK: lookups for the agent
    func title(_ id: String) -> String {
        notes[id]?.analysis?.title ?? Self.dateString(id)
    }

    static func dateString(_ id: String) -> String {
        guard let t = TimeInterval(id) else { return id }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: t))
    }

    /// Keyword search over titles, summaries, topics and transcripts. Newest first among equals.
    func search(_ query: String, limit: Int = 8) -> [[String: Any]] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
        var scored: [(Int, String)] = []
        for (id, n) in notes {
            let head = [n.analysis?.title, n.analysis?.summary, n.analysis?.topics.joined(separator: " "),
                        n.analysis?.speakers.map(\.name).joined(separator: " ")].compactMap { $0 }.joined(separator: " ").lowercased()
            let body = (n.segments ?? []).map(\.text).joined(separator: " ").lowercased()
            var score = words.isEmpty ? 1 : 0
            for w in words {
                if head.contains(w) { score += 3 }
                if body.contains(w) { score += 1 }
            }
            if score > 0 { scored.append((score, id)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }
        return scored.prefix(limit).map { _, id in
            let n = notes[id]!
            var r: [String: Any] = ["recording_id": id, "recorded": Self.dateString(id), "title": title(id)]
            if let a = n.analysis { r["summary"] = a.summary; r["speakers"] = a.speakers.map(\.name) }
            if let w = words.first, let seg = n.segments?.first(where: { $0.text.lowercased().contains(w) }) {
                r["matching_line"] = "[\(fmtTime(seg.start))] \(n.speakerName(seg.speaker)): \(seg.text)"
            }
            if n.analysis == nil && n.segments == nil { r["note"] = "not transcribed yet" }
            return r
        }
    }

    func detail(_ id: String) -> [String: Any]? {
        guard let n = notes[id] else { return nil }
        var r: [String: Any] = ["recording_id": id, "recorded": Self.dateString(id)]
        if let a = n.analysis {
            r["title"] = a.title
            r["summary"] = a.summary
            r["speakers"] = a.speakers.map { "\($0.label) = \($0.name)" + ($0.isWearer ? " (the user)" : "") }
            r["insights"] = a.insights
            r["decisions"] = a.decisions
            r["action_items"] = a.actionItems.map { "\($0.done ? "[done] " : "")\($0.text)" + ($0.owner.isEmpty ? "" : " — \($0.owner)") + ($0.due.isEmpty ? "" : " (due \($0.due))") }
        }
        r["transcript"] = n.transcriptText(maxChars: 60_000)
        return r
    }

    func openActionItems(includeDone: Bool) -> [[String: Any]] {
        notes.keys.sorted(by: >).flatMap { id -> [[String: Any]] in
            (notes[id]?.analysis?.actionItems ?? []).filter { includeDone || !$0.done }.map {
                ["recording_id": id, "recording": title(id), "text": $0.text, "owner": $0.owner,
                 "due": $0.due, "done": $0.done]
            }
        }
    }
}
