import Foundation

/// One reversible edit, stored as the state needed to go back. Applying it returns its inverse,
/// so the same type serves undo and redo. Entries are page-sized (not whole notebooks) so a
/// long history stays small enough to persist.
public enum HistoryChange: Codable, Hashable, Sendable {
    /// Restore this page's content (matched by id).
    case page(Page)
    /// Re-insert a page that an edit removed.
    case insertPage(Page, at: Int)
    /// Remove a page that an edit inserted.
    case removePage(UUID)

    /// The page this change concerns.
    public var pageID: UUID {
        switch self {
        case .page(let p), .insertPage(let p, _): p.id
        case .removePage(let id): id
        }
    }

    /// Applies the change and returns its inverse, or nil when it no longer applies
    /// (e.g. the page is gone, or removing it would leave the notebook empty).
    public func apply(to notebook: inout Notebook) -> HistoryChange? {
        switch self {
        case .page(let page):
            guard let i = notebook.pages.firstIndex(where: { $0.id == page.id }) else { return nil }
            let inverse = HistoryChange.page(notebook.pages[i])
            notebook.pages[i] = page
            return inverse
        case .insertPage(let page, let index):
            guard !notebook.pages.contains(where: { $0.id == page.id }) else { return nil }
            notebook.pages.insert(page, at: min(max(0, index), notebook.pages.count))
            return .removePage(page.id)
        case .removePage(let id):
            guard notebook.pages.count > 1, let i = notebook.pages.firstIndex(where: { $0.id == id }) else { return nil }
            let inverse = HistoryChange.insertPage(notebook.pages[i], at: i)
            notebook.pages.remove(at: i)
            return inverse
        }
    }
}

public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var change: HistoryChange
    /// Raster layer whose bitmap was captured with this entry (stored next to it as PNG).
    public var rasterLayer: UUID?

    public init(id: UUID = UUID(), change: HistoryChange, rasterLayer: UUID? = nil) {
        self.id = id; self.change = change; self.rasterLayer = rasterLayer
    }
}
