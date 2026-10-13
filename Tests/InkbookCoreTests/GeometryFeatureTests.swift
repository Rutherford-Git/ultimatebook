import XCTest
@testable import InkbookCore

final class GeometryFeatureTests: XCTestCase {
    func testOutlineWidthFollowsPressureAndIsClosed() {
        let brush = Brush(kind: .pen, color: .black, size: 10, minSizeRatio: 0.2)
        let stroke = Stroke(brush: brush, points: [InkPoint(Point(0, 0), pressure: 0), InkPoint(Point(50, 0), pressure: 0.5),
                                                   InkPoint(Point(100, 0), pressure: 1)])
        let path = StrokeOutline.outline(for: stroke)
        XCTAssertEqual(path.first, .move(Point(0, 1)))      // radius 1 at pressure 0 (2 / 2), left normal = +y
        XCTAssertEqual(path.last, .close)
        let ys = path.flatMap(\.points).filter { abs($0.x - 100) < 1e-9 }.map(\.y)
        XCTAssertEqual(ys.max() ?? 0, 5, accuracy: 1e-9)    // radius 5 at full pressure
        let bounds = Rect.bounding(path.flatMap(\.points))!
        XCTAssertEqual(bounds.maxX, 105, accuracy: 1e-9)     // round cap extends one radius
        XCTAssertTrue(stroke.usesOutline)
        XCTAssertFalse(Stroke(brush: .highlighter, points: stroke.points).usesOutline)
    }

    func testOutlineHandlesDotsAndDuplicatePoints() {
        let dot = StrokeOutline.outline(for: Stroke(brush: .pen, points: [InkPoint(Point(5, 5)), InkPoint(Point(5, 5))]))
        XCTAssertEqual(dot.count, 17)   // circle: move + 15 lines + close
        XCTAssertTrue(StrokeOutline.outline(for: Stroke(brush: .pen, points: [])).isEmpty)
    }

    func testLassoSelectsMostlyEnclosedElementsOnly() {
        let square = [Point(0, 0), Point(100, 0), Point(100, 100), Point(0, 100)]
        XCTAssertTrue(Lasso.contains(square, Point(50, 50)))
        XCTAssertFalse(Lasso.contains(square, Point(150, 50)))
        let inside = Element.stroke(Stroke(brush: .pen, points: (0..<10).map { InkPoint(Point(10 + Double($0), 10)) }))
        // Mostly outside (25% inside) with its center outside: not selected.
        let poking = Element.stroke(Stroke(brush: .pen, points: (0..<41).map { InkPoint(Point(90 + Double($0), 50)) }))
        let note = Element.text(TextBox(frame: Rect(x: 20, y: 20, width: 30, height: 30), text: "x"))
        let outside = Element.highlight(HighlightRegion(frame: Rect(x: 200, y: 200, width: 10, height: 10)))
        XCTAssertEqual(Set(Lasso.select(square, in: [inside, poking, note, outside])), [inside.id, note.id])
        XCTAssertEqual(Lasso.bounds(of: [note.id], in: [inside, note]), Rect(x: 20, y: 20, width: 30, height: 30))
    }

    func testLassoSelectsHighlighterOverhangingTheLassoedWords() {
        let lasso = [Point(20, 20), Point(120, 20), Point(120, 60), Point(20, 60)]
        // Highlight runs 35% past the lasso on the right, but its center is inside.
        let highlight = Element.stroke(Stroke(brush: .highlighter, points: [InkPoint(Point(30, 40)), InkPoint(Point(165, 40))]))
        // Slowly written start (many samples clustered inside) must not make a mostly-outside stroke count.
        let clustered = Element.stroke(Stroke(brush: .pen, points: (0..<50).map { _ in InkPoint(Point(110, 40)) }
            + [InkPoint(Point(300, 40))]))
        XCTAssertEqual(Lasso.select(lasso, in: [highlight, clustered]), [highlight.id])
    }

    func testSelfCrossingLassoCountsBothLoops() {
        // Figure-eight: left loop around (25, 25), right loop around (75, 25).
        let eight = [Point(0, 0), Point(100, 50), Point(100, 0), Point(0, 50)]
        XCTAssertTrue(Lasso.contains(eight, Point(10, 25)))
        XCTAssertTrue(Lasso.contains(eight, Point(90, 25)))
        XCTAssertFalse(Lasso.contains(eight, Point(50, 45)))
    }

    func testElementTranslateAndDuplicate() {
        let shape = Element.shape(FilledShape(path: [.move(Point(0, 0)), .cubic(control1: Point(1, 1), control2: Point(2, 2), to: Point(3, 3)), .close],
                                              color: .black))
        guard case .shape(let moved) = shape.translated(by: Point(10, 20)) else { return XCTFail() }
        XCTAssertEqual(moved.path[1], .cubic(control1: Point(11, 21), control2: Point(12, 22), to: Point(13, 23)))
        XCTAssertEqual(moved.id, shape.id)
        XCTAssertNotEqual(shape.withNewID().id, shape.id)
    }

    func testTranscriptGroupsLinesInReadingOrder() {
        let w = { (x: Double, y: Double, t: String) in TextLayout.Word(frame: Rect(x: x, y: y, width: 40, height: 20), text: t) }
        XCTAssertEqual(TextLayout.transcript([w(200, 102, "world"), w(10, 100, "hello"), w(10, 160, "next"), w(0, 0, "")]),
                       "hello world\nnext")
    }

    func testPDFImportBuildsOnePagePerPDFPage() throws {
        let nb = try PDFImport.notebook(title: "Lecture", asset: "lecture.pdf",
                                        pages: [.init(size: Size(612, 792)), .init(size: Size(792, 612))])
        XCTAssertEqual(nb.pages.map(\.size), [Size(612, 792), Size(792, 612)])
        XCTAssertEqual(nb.pages.map(\.paper), [.asset("lecture.pdf", pdfPage: 0), .asset("lecture.pdf", pdfPage: 1)])
        XCTAssertThrowsError(try PDFImport.notebook(title: "x", asset: "a", pages: [])) {
            XCTAssertEqual($0 as? PDFImport.Failure, .noPages)
        }
        XCTAssertThrowsError(try PDFImport.notebook(title: "x", asset: "a", pages: [.init(size: Size(0, 10))]))
    }

    func testNotebooksSavedBeforeDashFieldStillDecode() throws {
        let json = #"{"kind":"pen","color":{"r":0,"g":0,"b":0,"a":1},"size":2,"minSizeRatio":0.35,"spacing":0.15,"softness":0}"#
        let brush = try JSONDecoder().decode(Brush.self, from: Data(json.utf8))
        XCTAssertNil(brush.dash)
    }
}
