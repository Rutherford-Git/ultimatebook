import Foundation

/// How a page differs from an earlier version of itself. Drives redraws: an undo that only moved
/// or removed a few elements only needs that area repainted.
public enum PageChange: Equatable, Sendable {
    case none
    /// Only elements inside this rect (page points) differ.
    case area(Rect)
    /// Layers, paper or page size differ, or the change cannot be bounded.
    case wholePage
}

public extension Page {
    static func change(from before: Page, to after: Page) -> PageChange {
        guard before.id == after.id, before.size == after.size, before.paper == after.paper,
              before.layers.map(\.id) == after.layers.map(\.id) else { return .wholePage }

        var area: Rect?
        for (old, new) in zip(before.layers, after.layers) {
            // Layer settings (visibility, lock, opacity, blend, kind) repaint everything.
            var oldSettings = old, newSettings = new
            oldSettings.elements = []; newSettings.elements = []
            guard oldSettings == newSettings else { return .wholePage }
            if old.elements == new.elements { continue }

            let oldByID = Dictionary(uniqueKeysWithValues: old.elements.map { ($0.id, $0) })
            let newByID = Dictionary(uniqueKeysWithValues: new.elements.map { ($0.id, $0) })
            var changed: [Element] = []
            for (id, element) in oldByID where newByID[id] != element { changed.append(element) }
            for (id, element) in newByID where oldByID[id] != element { changed.append(element) }
            for element in changed {
                guard let b = element.bounds else { return .wholePage }
                area = area.map { Rect.bounding([$0.origin, Point($0.maxX, $0.maxY), b.origin, Point(b.maxX, b.maxY)])! } ?? b
            }
        }
        return area.map { .area($0) } ?? .none
    }
}
