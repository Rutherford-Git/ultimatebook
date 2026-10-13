import XCTest
@testable import InkbookCore

final class HistoryTests: XCTestCase {
    func testChangesInvertAcrossUndoAndRedo() throws {
        var nb = Notebook(title: "t", pages: [Page(), Page()])
        let original = nb
        let edited = { () -> Page in
            var p = nb.pages[0]
            p.layers[0].elements.append(.text(TextBox(frame: Rect(x: 0, y: 0, width: 10, height: 10), text: "x")))
            return p
        }()
        // Edit page 0, recording the before-state as the undo change.
        let undo = HistoryChange.page(nb.pages[0])
        nb.pages[0] = edited
        let redo = try XCTUnwrap(undo.apply(to: &nb))
        XCTAssertEqual(nb, original)
        XCTAssertNotNil(redo.apply(to: &nb))
        XCTAssertEqual(nb.pages[0], edited)

        // Page insertion: undo removes it, redo puts it back at the same index.
        let inserted = Page()
        nb.pages.insert(inserted, at: 1)
        let undoInsert = HistoryChange.removePage(inserted.id)
        let redoInsert = try XCTUnwrap(undoInsert.apply(to: &nb))
        XCTAssertEqual(nb.pages.count, 2)
        XCTAssertEqual(redoInsert, .insertPage(inserted, at: 1))
        _ = redoInsert.apply(to: &nb)
        XCTAssertEqual(nb.pages[1].id, inserted.id)

        // Never removes the last page; unknown pages are a no-op.
        var single = Notebook(title: "s")
        XCTAssertNil(HistoryChange.removePage(single.pages[0].id).apply(to: &single))
        XCTAssertNil(HistoryChange.page(Page()).apply(to: &single))
    }

    func testHistoryPersistsTrimsAndCollectsGarbage() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let store = HistoryStore(bundle: bundle, maxEntries: 3)
        let entries = (0..<5).map { _ in HistoryEntry(change: .page(Page()), rasterLayer: UUID()) }
        for e in entries { try store.write(e); try store.writeRaster(Data([1, 2, 3]), for: e.id) }
        let redo = HistoryEntry(change: .removePage(UUID()))
        try store.write(redo)

        let dropped = try store.saveIndex(undo: entries.map(\.id), redo: [redo.id])
        XCTAssertEqual(dropped, entries.prefix(2).map(\.id))

        let loaded = HistoryStore(bundle: bundle, maxEntries: 3).load()
        XCTAssertEqual(loaded.undo, Array(entries.suffix(3)))
        XCTAssertEqual(loaded.redo, [redo])
        XCTAssertEqual(store.rasterData(for: entries[4].id), Data([1, 2, 3]))
        XCTAssertNil(store.rasterData(for: entries[0].id))   // trimmed files are deleted
        XCTAssertFalse(store.hasEntry(entries[0].id))
    }

    func testDamagedHistoryLosesOnlyDamagedSteps() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let store = HistoryStore(bundle: bundle)
        let good = HistoryEntry(change: .page(Page())), bad = HistoryEntry(change: .page(Page()))
        try store.write(good); try store.write(bad)
        try store.saveIndex(undo: [good.id, bad.id], redo: [])
        try Data("garbage".utf8).write(to: store.directory.appendingPathComponent("\(bad.id.uuidString).json"))
        XCTAssertEqual(store.load().undo, [good])
        XCTAssertTrue(HistoryStore(bundle: bundle.appendingPathComponent("missing")).load().undo.isEmpty)
    }

    func testByteBudgetDropsOldestUndoFirst() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let store = HistoryStore(bundle: bundle, maxEntries: 100, maxBytes: 2500)
        let entries = (0..<3).map { _ in HistoryEntry(change: .page(Page())) }
        for e in entries { try store.write(e); try store.writeRaster(Data(repeating: 0, count: 1000), for: e.id) }
        let dropped = try store.saveIndex(undo: entries.map(\.id), redo: [])
        XCTAssertEqual(dropped, [entries[0].id, entries[1].id])
        XCTAssertEqual(store.load().undo, [entries[2]])
    }
}
