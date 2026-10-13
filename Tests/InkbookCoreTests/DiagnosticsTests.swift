import XCTest
@testable import InkbookCore

final class DiagnosticsTests: XCTestCase {
    /// A wobbly, pressure-varying scribble like fast handwriting.
    static func scribble(_ count: Int, seed: Double = 1) -> [InkPoint] {
        (0..<count).map { i in
            let t = Double(i)
            return InkPoint(Point(40 + t * 1.7 + 6 * sin(t * 0.9 * seed), 300 + 25 * sin(t * 0.37) + 3 * cos(t * 2.1)),
                            pressure: 0.35 + 0.3 * sin(t * 0.21), time: t / 240)
        }
    }

    func testLiveStrokeMatchesBatchSmoothAndSimplify() {
        for count in [1, 2, 3, 5, 40, 400] {
            let raw = Self.scribble(count)
            var live = LiveStroke(brush: .pen)
            raw.forEach { live.add($0) }
            let batch = BrushEngine.simplify(BrushEngine.smooth(raw, strength: 0.5), minDistance: 0.6)
            XCTAssertEqual(live.finished(), batch, "count \(count)")
        }
    }

    func testLiveStrokePiecesAndTail() {
        var live = LiveStroke(brush: .pen)
        XCTAssertNotNil(live.add(InkPoint(Point(0, 0))))       // first sample settles a dot
        XCTAssertNil(live.add(InkPoint(Point(10, 0))))         // held back until the next sample
        XCTAssertNotNil(live.add(InkPoint(Point(20, 0))))      // settles the previous one
        XCTAssertEqual(live.kept.count, 2)
        XCTAssertEqual(live.pieceBounds.count, live.kept.count)
        let tail = live.tail(predicted: [InkPoint(Point(25, 0))])
        XCTAssertEqual(tail.map(\.location), [Point(5, 0), Point(20, 0), Point(25, 0)])
        // Each piece's bounds contain both of its end points.
        for i in 1..<live.kept.count {
            let r = live.pieceBounds[i]
            for p in [live.kept[i - 1].location, live.kept[i].location] {
                XCTAssertTrue(p.x >= r.minX && p.x <= r.maxX && p.y >= r.minY && p.y <= r.maxY)
            }
        }
    }

    /// Prints the geometry cost per frame of the old (rebuild whole outline) and new (one piece)
    /// live-ink paths. CPU only; drawing cost is measured on device by the in-app self-test.
    func testLiveInkGeometryCostPerFrame() {
        for count in [100, 400, 1600] {
            let raw = Self.scribble(count)
            var start = Date()
            for n in stride(from: 3, through: count, by: 3) {
                _ = StrokeOutline.outline(for: Stroke(brush: .pen, points: Array(raw.prefix(n))))
            }
            let legacy = Date().timeIntervalSince(start) * 1000 / Double(count / 3)
            start = Date()
            var live = LiveStroke(brush: .pen)
            for p in raw { live.add(p) }
            _ = live.tail(predicted: [])
            let incremental = Date().timeIntervalSince(start) * 1000 / Double(count / 3)
            print(String(format: "live ink geometry, %d samples: legacy %.4f ms/frame, incremental %.4f ms/frame",
                         count, legacy, incremental))
            XCTAssertEqual(live.finished().count, BrushEngine.simplify(BrushEngine.smooth(raw, strength: 0.5), minDistance: 0.6).count)
        }
    }

    func testDiagnosticsLogPersistsAndTrims() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("diagnostics.jsonl")
        let log = DiagnosticsLog(fileURL: url, capacity: 5)
        for i in 0..<12 { log.info("test", "event \(i)") }
        log.error("save", "disk full")
        XCTAssertEqual(log.entries.count, 5)
        XCTAssertEqual(log.entries.last?.message, "disk full")

        let reopened = DiagnosticsLog(fileURL: url, capacity: 5)
        XCTAssertEqual(reopened.entries.map(\.message), log.entries.map(\.message))
        let report = reopened.report(minimum: .warning)
        XCTAssertTrue(report.contains("1 errors"))
        XCTAssertTrue(report.contains("ERROR [save] disk full"))
        XCTAssertFalse(report.contains("event 11"))
        reopened.clear()
        XCTAssertTrue(DiagnosticsLog(fileURL: url).entries.isEmpty)
    }

    func testPerfPercentiles() {
        let s = PerfRecorder.summarize("frame", (1...100).map(Double.init))!
        XCTAssertEqual(s.p50, 50)
        XCTAssertEqual(s.p95, 95)
        XCTAssertEqual(s.max, 100)
        let rec = PerfRecorder(window: 3)
        [5, 1, 9, 7].forEach { rec.record("x", ms: $0) }
        XCTAssertEqual(rec.summary("x")?.count, 3)
        XCTAssertEqual(rec.summary("x")?.max, 9)
    }

    func testImprovementNotesRoundTripAndText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/notes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ImprovementNotesStore(url: url)
        XCTAssertTrue(store.load().isEmpty)
        let old = ImprovementNote(created: Date(timeIntervalSince1970: 1_700_000_000), text: "Lasso misses highlighter",
                                  category: .bug, isDone: true)
        let new = ImprovementNote(created: Date(timeIntervalSince1970: 1_700_100_000), text: "Ink lags when scribbling",
                                  category: .performance, context: "Physics 2, page 3")
        try store.save([old, new])
        XCTAssertEqual(store.load(), [old, new])
        let text = ImprovementNotesStore.plainText(store.load())
        XCTAssertTrue(text.hasPrefix("Inkbook improvement notes: 1 open, 1 done."))
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines[1].contains("[ ]") && lines[1].contains("Performance (Physics 2, page 3): Ink lags"))
        XCTAssertTrue(lines[2].contains("[x]"))
    }

    func testAppToolsReportOrSayUnavailable() async {
        let host = FakeHost(Notebook(title: "T"))
        var out = await NotebookTools.run("read_diagnostics", input: [:], host: host)
        XCTAssertEqual(out.text, "Diagnostics are not available.")
        host.diagnostics = "Inkbook diagnostics: 1 entries"
        out = await NotebookTools.run("read_diagnostics", input: [:], host: host)
        XCTAssertEqual(out.text, "Inkbook diagnostics: 1 entries")
        XCTAssertFalse(out.isError)
        out = await NotebookTools.run("run_self_test", input: [:], host: host)
        XCTAssertEqual(out.text, "Self-test is not available.")
        let names = NotebookTools.definitions.compactMap { $0["name"]?.string }
        XCTAssertEqual(Array(names.suffix(3)), ["read_diagnostics", "read_improvement_notes", "run_self_test"])
    }
}
