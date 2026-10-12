import XCTest
@testable import InkbookCore

final class ModelAndStorageTests: XCTestCase {
    func testColorHexRoundTripAndRejectsMalformed() {
        let c = RGBA(hex: "#FF800040")!
        XCTAssertEqual(c.hex, "#FF800040")
        XCTAssertEqual(RGBA(hex: "00FF00")?.a, 1)
        XCTAssertNil(RGBA(hex: "#12345"))
        XCTAssertNil(RGBA(hex: "#GGGGGG"))
    }

    func testAgentProposalOnlyTouchesAgentLayer() throws {
        var notebook = Notebook(title: "T")
        let userInk = Element.stroke(Stroke(brush: .pen, points: [InkPoint(Point(1, 1))]))
        notebook.pages[0].layers[0].elements = [userInk]
        let note = TextBox(frame: Rect(x: 10, y: 10, width: 100, height: 40), text: "hi")
        try AgentProposal.note(pageIndex: 0, box: note).apply(to: &notebook)
        try AgentProposal.highlight(pageIndex: 0, region: HighlightRegion(frame: Rect(x: 0, y: 0, width: 5, height: 5))).apply(to: &notebook)

        XCTAssertEqual(notebook.pages[0].layers.count, 2)
        XCTAssertEqual(notebook.pages[0].layers[0].elements, [userInk])
        XCTAssertEqual(notebook.pages[0].layers[1].kind, .agent)
        XCTAssertEqual(notebook.pages[0].layers[1].elements.count, 2)
        XCTAssertThrowsError(try AgentProposal.note(pageIndex: 3, box: note).apply(to: &notebook))
    }

    func testStoreRoundTripsNotebookRasterAndAssets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkbook-\(UUID().uuidString).inkbook")
        defer { try? FileManager.default.removeItem(at: dir) }
        var notebook = Notebook(title: "Physics")
        notebook.pages[0].layers.append(Layer(name: "Paint", kind: .raster, opacity: 0.5, blendMode: .multiply))
        notebook.pages[0].layers[0].elements = [
            .stroke(Stroke(brush: .highlighter, points: [InkPoint(Point(1, 2), pressure: 0.4, tilt: 0.2, time: 0.1)])),
            .text(TextBox(frame: Rect(x: 1, y: 2, width: 3, height: 4), text: "E = kq/r\u{00B2}")),
        ]
        notebook.pages[0].paper = .asset("bg.pdf", pdfPage: 2)
        let store = try NotebookStore.create(at: dir, notebook: notebook)
        try store.saveRaster(Data([1, 2, 3]), for: notebook.pages[0].layers[1].id)
        try store.saveAsset(Data([4, 5]), named: "bg.pdf")
        try store.save(notebook)   // overwrite path (replaceItemAt)

        let loaded = try NotebookStore(url: dir).load()
        XCTAssertEqual(loaded.pages, notebook.pages)
        XCTAssertEqual(loaded.title, "Physics")
        XCTAssertEqual(store.rasterData(for: notebook.pages[0].layers[1].id), Data([1, 2, 3]))
        XCTAssertEqual(try store.assetData(named: "bg.pdf"), Data([4, 5]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testStoreRejectsNewerSchemaCorruptManifestAndPathEscape() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkbook-\(UUID().uuidString).inkbook")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NotebookStore.create(at: dir, notebook: Notebook(title: "x"))
        XCTAssertThrowsError(try store.saveAsset(Data(), named: "../escape")) {
            XCTAssertEqual($0 as? StoreError, .invalidName("../escape"))
        }
        let manifest = dir.appendingPathComponent("manifest.json")
        try Data(#"{"schemaVersion": 99, "notebook": {}}"#.utf8).write(to: manifest)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? StoreError, .unsupportedSchema(found: 99, supported: Notebook.schemaVersion))
        }
        try Data("not json".utf8).write(to: manifest)
        XCTAssertThrowsError(try store.load()) { error in
            guard case .corrupt? = error as? StoreError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try NotebookStore(url: dir.appendingPathComponent("missing")).load())
    }
}

final class BrushEngineTests: XCTestCase {
    func testDiameterFollowsPressureWithinBrushRange() {
        let b = Brush(kind: .pen, color: .black, size: 10, minSizeRatio: 0.2)
        XCTAssertEqual(BrushEngine.diameter(for: b, pressure: 0), 2, accuracy: 1e-9)
        XCTAssertEqual(BrushEngine.diameter(for: b, pressure: 1), 10, accuracy: 1e-9)
        XCTAssertEqual(BrushEngine.diameter(for: b, pressure: 7), 10, accuracy: 1e-9)   // clamped
        XCTAssertGreaterThan(BrushEngine.diameter(for: b, pressure: 0.5), 6)          // ease-out
    }

    func testDabsAreEvenlySpacedAndIncrementalMatchesWhole() {
        let brush = Brush(kind: .marker, color: .black, size: 10, minSizeRatio: 1, spacing: 0.5)
        let pts = (0...10).map { InkPoint(Point(Double($0) * 7, 0)) }
        var carry = 0.0
        let whole = BrushEngine.dabs(along: pts, brush: brush, carry: &carry)
        XCTAssertEqual(whole.count, 14)   // 70 pt / 5 pt spacing
        for (a, b) in zip(whole, whole.dropFirst()) {
            XCTAssertEqual(b.center.x - a.center.x, 5, accuracy: 1e-9)
        }
        var carry2 = 0.0
        let first = BrushEngine.dabs(along: Array(pts[0...4]), brush: brush, carry: &carry2)
        let rest = BrushEngine.dabs(along: Array(pts[4...]), brush: brush, carry: &carry2)
        XCTAssertEqual(first + rest, whole)
    }

    func testSmoothingKeepsEndpointsAndEraserHitsOnlyNearbyStrokes() {
        let pts = [InkPoint(Point(0, 0)), InkPoint(Point(5, 10)), InkPoint(Point(10, 0))]
        let s = BrushEngine.smooth(pts, strength: 0.8)
        XCTAssertEqual(s.first, pts.first)
        XCTAssertEqual(s.last, pts.last)
        XCTAssertLessThan(s[1].location.y, 10)

        let near = Stroke(brush: .pen, points: [InkPoint(Point(0, 0))])
        let far = Stroke(brush: .pen, points: [InkPoint(Point(100, 100))])
        XCTAssertEqual(BrushEngine.strokesHit(by: Point(3, 0), radius: 2, in: [.stroke(near), .stroke(far)]), [near.id])
    }
}
