import Foundation

/// Long-term memory for the ring agent: short facts worth knowing later (people, projects,
/// preferences, commitments). Stored as JSON in Application Support, on this iPhone only.
struct MemoryItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var about: String       // person / topic, may be ""
    var source: String      // "chat", "you", or a recording id
    var createdAt: Date
}

final class MemoryStore: ObservableObject {
    @Published private(set) var items: [MemoryItem] = []

    static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoxLibre", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private let file = MemoryStore.dir.appendingPathComponent("memory.json")

    init() {
        if let d = try? Data(contentsOf: file),
           let v = try? JSONDecoder.iso.decode([MemoryItem].self, from: d) { items = v }
    }

    @discardableResult
    func add(_ text: String, about: String = "", source: String) -> MemoryItem? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // skip near-duplicates
        if let same = items.first(where: { $0.text.caseInsensitiveCompare(t) == .orderedSame }) { return same }
        let m = MemoryItem(id: Self.newId(), text: String(t.prefix(500)), about: about, source: source, createdAt: Date())
        items.insert(m, at: 0)
        save()
        return m
    }

    func update(_ m: MemoryItem) {
        guard let i = items.firstIndex(where: { $0.id == m.id }) else { return }
        items[i] = m
        save()
    }

    @discardableResult
    func remove(_ id: String) -> Bool {
        let n = items.count
        items.removeAll { $0.id == id }
        save()
        return items.count != n
    }

    func removeAll(source: String) {
        items.removeAll { $0.source == source }
        save()
    }

    /// The memory block for system prompts.
    var promptText: String {
        guard !items.isEmpty else { return "You don't remember anything yet." }
        return items.prefix(300).map { m in
            "- [\(m.id)] " + (m.about.isEmpty ? "" : "(\(m.about)) ") + m.text
        }.joined(separator: "\n")
    }

    private func save() {
        if let d = try? JSONEncoder.iso.encode(items) { try? d.write(to: file, options: .atomic) }
    }

    static func newId() -> String { "m" + String(UUID().uuidString.prefix(6)).lowercased() }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
