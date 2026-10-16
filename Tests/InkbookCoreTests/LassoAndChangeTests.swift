import XCTest
@testable import InkbookCore

final class LassoAndChangeTests: XCTestCase {
    /// Lasso around (0,0)-(300,300).
    let box = [Point(0, 0), Point(300, 0), Point(300, 300), Point(0, 300)]

    func stroke(_ x: Double, _ y: Double, _ n: Int = 10) -> Element {
        .stroke(Stroke(brush: .pen, points: (0..<n).map { InkPoint(Point(x + Double($0) * 2, y)) }))
    }

    func mixedPage() -> Page {
        var page = Page()
        page.layers[0].elements = [stroke(10, 10), stroke(500, 500)]   // Ink, first
        page.layers.append(Layer(name: "Ink 2", kind: .vector, elements: [
            .text(TextBox(frame: Rect(x: 40, y: 40, width: 80, height: 30), text: "x")),
            .highlight(HighlightRegion(frame: Rect(x: 20, y: 120, width: 200, height: 20))),
        ]))
        page.layers.append(Layer(name: "Agent", kind: .agent, elements: [.highlight(HighlightRegion(frame: Rect(x: 60, y: 200, width: 40, height: 20)))]))
        page.layers.append(Layer(name: "Paint 1", kind: .raster))
        return page
    }

    func testMixedLayersSelectEverythingInsideAcrossLayers() {
        let report = mixedPage().lassoReport(box)
        XCTAssertEqual(report.selected.count, 4)   // stroke, text, highlight, agent highlight
        XCTAssertEqual(report.layers.map(\.name), ["Ink", "Ink 2", "Agent"])
        XCTAssertEqual(report.layers.map(\.hit), [1, 2, 1])
        XCTAssertNil(report.notice)
    }

    func testHiddenAndLockedItemsAreCountedNotSelected() {
        var page = mixedPage()
        page.layers[1].isVisible = false     // Ink 2 hidden
        page.layers[2].isLocked = true       // Agent locked
        let report = page.lassoReport(box)
        XCTAssertEqual(report.selected.count, 1)
        XCTAssertEqual(report.skippedHidden, [.init(name: "Ink 2", hit: 2, total: 2)])
        XCTAssertEqual(report.skippedLocked, [.init(name: "Agent", hit: 1, total: 1)])
        XCTAssertEqual(report.notice, "2 items on hidden \u{201C}Ink 2\u{201D} not selected\n1 item on locked \u{201C}Agent\u{201D} not selected")
    }

    func testPaintUnderTheLassoIsReportedNotSilent() {
        let report = mixedPage().lassoReport(box, paintUnder: ["Paint 1"])
        XCTAssertEqual(report.paintUnder, ["Paint 1"])
        XCTAssertEqual(report.notice, "Paint can't be lassoed yet (Paint 1)")
        XCTAssertTrue(report.summary.contains("paint not selectable: Paint 1"))
    }

    func testLassoOutsideEverythingSelectsNothingAndSaysNothing() {
        let far = [Point(900, 900), Point(950, 900), Point(950, 950)]
        let report = mixedPage().lassoReport(far)
        XCTAssertTrue(report.selected.isEmpty)
        XCTAssertNil(report.notice)
    }

    func testSamePageGivesSameSelectionAfterStoreRoundTrip() throws {
        let page = mixedPage()
        let data = try JSONEncoder().encode(Notebook(title: "t", pages: [page]))
        let back = try JSONDecoder().decode(Notebook.self, from: data).pages[0]
        XCTAssertEqual(back.lassoReport(box).selected, page.lassoReport(box).selected)
    }

    func testPageChangeDetectsOnlyTheChangedArea() {
        let before = mixedPage()
        var after = before
        after.layers[0].elements.removeAll { ($0.bounds?.minX ?? 999) < 100 }      // undo of an added stroke
        guard case .area(let r) = Page.change(from: before, to: after) else { return XCTFail("expected area") }
        XCTAssertTrue(r.minX <= 10 && r.maxX >= 10 + 18 && r.minY <= 10 && r.maxY >= 10)
        XCTAssertFalse(r.intersects(Rect(x: 400, y: 400, width: 200, height: 200)))   // the other stroke is not dirty

        XCTAssertEqual(Page.change(from: before, to: before), .none)
        var layerAdded = before
        layerAdded.layers.append(Layer(name: "Ink 3", kind: .vector))
        XCTAssertEqual(Page.change(from: before, to: layerAdded), .wholePage)
        var hidden = before
        hidden.layers[1].isVisible = false
        XCTAssertEqual(Page.change(from: before, to: hidden), .wholePage)
    }

    func testPageChangeMovedElementDirtiesOldAndNewPlaces() {
        let before = mixedPage()
        var after = before
        after.layers[0].elements = after.layers[0].elements.map { $0.translated(by: Point(200, 0)) }
        guard case .area(let r) = Page.change(from: before, to: after) else { return XCTFail("expected area") }
        XCTAssertTrue(r.minX <= 10 && r.maxX >= 210 + 18)   // covers old and new position of the first stroke
    }
}
