import Foundation

/// Turns positioned words (from Goodnotes' search index or on-device recognition) into a
/// reading-order transcript: words grouped into lines by vertical center, lines top to bottom.
public enum TextLayout {
    public struct Word: Equatable, Sendable {
        public var frame: Rect
        public var text: String
        public init(frame: Rect, text: String) { self.frame = frame; self.text = text }
    }

    public static func transcript(_ words: [Word]) -> String {
        let sorted = words.filter { !$0.text.isEmpty }
            .sorted { center($0) < center($1) }
        var lines: [(center: Double, words: [Word])] = []
        for w in sorted {
            let c = center(w)
            if let last = lines.last, abs(last.center - c) < max(w.frame.size.height, 12) * 0.6 {
                lines[lines.count - 1].words.append(w)
            } else {
                lines.append((c, [w]))
            }
        }
        return lines.map { $0.words.sorted { $0.frame.minX < $1.frame.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    private static func center(_ w: Word) -> Double { w.frame.minY + w.frame.size.height / 2 }
}
