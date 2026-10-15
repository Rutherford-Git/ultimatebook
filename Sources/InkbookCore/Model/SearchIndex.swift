import Foundation

/// Searchable text of a notebook, one entry per page: typed text, recognized handwriting and
/// PDF text. Saved next to the manifest so the library can search without opening notebooks.
public struct SearchIndex: Codable, Equatable, Sendable {
    public var title: String
    /// Text per page, in page order (empty string for a page without text).
    public var pages: [String]

    public init(title: String, pages: [String]) {
        self.title = title; self.pages = pages
    }

    public init(_ notebook: Notebook) {
        self.init(title: notebook.title, pages: notebook.pages.map(\.allText))
    }

    public struct Hit: Equatable, Sendable, Identifiable {
        /// 0-based page index.
        public var page: Int
        /// The matching line, shortened around the match.
        public var snippet: String
        public var id: Int { page }
    }

    /// Pages containing `query` (ignoring case and accents), with a snippet each.
    public func hits(for query: String, limit: Int = 50) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [Hit] = []
        for (i, text) in pages.enumerated() where out.count < limit {
            if let snippet = Self.snippet(in: text, matching: q) { out.append(Hit(page: i, snippet: snippet)) }
        }
        return out
    }

    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The first line containing the query, trimmed to about `width` characters around the match.
    static func snippet(in text: String, matching query: String, width: Int = 80) -> String? {
        guard let range = text.range(of: query, options: options) else { return nil }
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let line = text[lineStart..<lineEnd]
        guard line.count > width else { return String(line).trimmingCharacters(in: .whitespaces) }
        let before = line.distance(from: line.startIndex, to: range.lowerBound)
        let start = line.index(line.startIndex, offsetBy: max(0, before - width / 3))
        let end = line.index(start, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex
        return (start > line.startIndex ? "…" : "") + line[start..<end].trimmingCharacters(in: .whitespaces)
            + (end < line.endIndex ? "…" : "")
    }
}
