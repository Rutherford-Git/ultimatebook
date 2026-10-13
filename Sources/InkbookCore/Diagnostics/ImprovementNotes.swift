import Foundation

/// The user's own running list of things to improve in Inkbook, kept on device.
public struct ImprovementNote: Codable, Hashable, Sendable, Identifiable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case bug, performance, idea, design

        public var title: String { rawValue.capitalized }
    }

    public var id: UUID
    public var created: Date
    public var text: String
    public var category: Category
    public var isDone: Bool
    /// Where the note was written from, e.g. "Physics 2, page 3".
    public var context: String?

    public init(id: UUID = UUID(), created: Date = Date(), text: String, category: Category = .idea,
                isDone: Bool = false, context: String? = nil) {
        self.id = id; self.created = created; self.text = text; self.category = category
        self.isDone = isDone; self.context = context
    }
}

public struct ImprovementNotesStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [ImprovementNote] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ImprovementNote].self, from: data)) ?? []
    }

    public func save(_ notes: [ImprovementNote]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(notes).write(to: url, options: .atomic)
    }

    /// Plain text for copying, sharing or the agent: open notes first, newest first.
    public static func plainText(_ notes: [ImprovementNote]) -> String {
        guard !notes.isEmpty else { return "No improvement notes yet." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let ordered = notes.sorted { ($0.isDone ? 1 : 0, $1.created) < ($1.isDone ? 1 : 0, $0.created) }
        let open = notes.filter { !$0.isDone }.count
        var lines = ["Inkbook improvement notes: \(open) open, \(notes.count - open) done."]
        for n in ordered {
            let ctx = n.context.map { " (\($0))" } ?? ""
            lines.append("- [\(n.isDone ? "x" : " ")] \(f.string(from: n.created)) \(n.category.title)\(ctx): \(n.text)")
        }
        return lines.joined(separator: "\n")
    }
}
