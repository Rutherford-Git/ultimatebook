import UIKit
import InkbookCore

/// Built-in test run on a scratch notebook (never the user's): an ink benchmark that compares
/// the current live-ink renderer with the previous one as the page fills up, plus functional
/// checks. Results go to the diagnostics log; the agent can run it with `run_self_test`.
@MainActor
enum SelfTest {
    private(set) static var isRunning = false

    static let strokeCount = 80
    static let samplesPerStroke = 150
    static let samplesPerFrame = 3   // ~240 Hz Pencil samples at 80 fps

    static func run() async -> String {
        guard !isRunning else { return "The self-test is already running." }
        isRunning = true
        defer { isRunning = false }
        let log = AppDiagnostics.log
        log.info("selftest", "Self-test started")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-\(UUID().uuidString).inkbook")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc: DocumentModel
        do {
            _ = try NotebookStore.create(at: dir, notebook: Notebook(title: "Self-test", pages: [Page(paper: .ruled(.white, spacing: 34))]))
            doc = try DocumentModel(store: NotebookStore(url: dir))
        } catch {
            log.error("selftest", "Could not create the scratch notebook: \(error)")
            return "Self-test could not start: \(error)"
        }
        defer { doc.cancelBackgroundWork() }

        var lines: [String] = []
        lines += await benchmark(doc)

        var checks: [(String, String?)] = []
        func check(_ name: String, _ body: () throws -> String?) {
            do { checks.append((name, try body())) } catch { checks.append((name, "threw \(error)")) }
        }
        func elementCount(_ d: DocumentModel) -> Int { d.page.layers.reduce(0) { $0 + $1.elements.count } }

        check("save and reload") {
            doc.saveNow(wait: true)
            let saved = try NotebookStore(url: dir).load()
            let n = saved.pages[0].layers.reduce(0) { $0 + $1.elements.count }
            return n == elementCount(doc) ? nil : "saved \(n) elements, expected \(elementCount(doc))"
        }
        check("undo and redo") {
            let before = elementCount(doc)
            doc.undo()
            let undone = elementCount(doc)
            doc.redo()
            return undone == before - 1 && elementCount(doc) == before ? nil : "counts \(before) → \(undone) → \(elementCount(doc))"
        }
        check("undo survives reopening") {
            doc.saveNow(wait: true)
            let reopened = try DocumentModel(store: NotebookStore(url: dir))
            defer { reopened.cancelBackgroundWork() }
            return reopened.canUndo ? nil : "no undo steps after reopening"
        }
        check("lasso selects pen and highlighter, even with a crossing loop") {
            let y = 1350.0
            doc.select(.highlighter)
            let mark = Stroke(brush: doc.brush, points: line(from: InkbookCore.Point(200, y), to: InkbookCore.Point(420, y)))
            doc.addStroke(mark)
            doc.select(.pen)
            let ink = Stroke(brush: doc.brush, points: wave(x: 210, y: y, width: 200, samples: 60))
            doc.addStroke(ink)
            doc.select(.lasso)
            // Loop around both, overlapping its own start (the case even-odd filling got wrong).
            let loop = [InkbookCore.Point(170, y - 50), InkbookCore.Point(460, y - 50), InkbookCore.Point(460, y + 50), InkbookCore.Point(170, y + 50),
                        InkbookCore.Point(170, y - 60), InkbookCore.Point(260, y - 60)]
            doc.lassoSelect(loop)
            let ok = doc.selection.contains(mark.id) && doc.selection.contains(ink.id)
            return ok ? nil : "selected \(doc.selection.count) of 2"
        }
        check("move selection") {
            guard let before = doc.selectionBounds else { return "nothing selected" }
            doc.moveSelection(by: InkbookCore.Point(30, 0))
            guard let after = doc.selectionBounds else { return "selection lost after moving" }
            doc.clearSelection()
            return abs(after.minX - before.minX - 30) < 0.5 ? nil : "moved by \(after.minX - before.minX)"
        }
        check("paint layer saves") {
            doc.select(.marker)
            guard let layer = doc.activeLayer, layer.kind == .raster,
                  let bitmap = doc.bitmap(for: layer, on: doc.page) else { return "no paint layer" }
            var carry = 0.0
            bitmap.stamp(BrushEngine.dabs(along: line(from: InkbookCore.Point(100, 100), to: InkbookCore.Point(300, 160)), brush: doc.brush, carry: &carry),
                         brush: doc.brush)
            doc.rasterStrokeEnded(dirty: nil)
            doc.saveNow(wait: true)
            doc.select(.pen)
            return NotebookStore(url: dir).rasterData(for: layer.id) == nil ? "paint layer not written" : nil
        }
        check("PDF export") {
            let url = try doc.exportPDF()
            defer { try? FileManager.default.removeItem(at: url) }
            let data = try Data(contentsOf: url)
            return data.starts(with: Data("%PDF".utf8)) && data.count > 1000 ? nil : "invalid PDF (\(data.count) bytes)"
        }
        let list = await NotebookTools.run("list_pages", input: [:], host: doc)
        checks.append(("agent can read the notebook", !list.isError && list.text.contains("page 1") ? nil : list.text))

        let failed = checks.filter { $0.1 != nil }
        for (name, why) in failed { log.error("selftest", "FAIL \(name): \(why!)") }
        let header = "Inkbook self-test: \(checks.count - failed.count)/\(checks.count) checks passed."
        let checkLines = checks.map { "\($0.1 == nil ? "PASS" : "FAIL") \($0.0)\($0.1.map { ": \($0)" } ?? "")" }
        let report = ([header] + lines + checkLines).joined(separator: "\n")
        log.log(failed.isEmpty ? .info : .error, "selftest", report)
        return report
    }

    // MARK: Ink benchmark

    /// Draws synthetic scribbles frame by frame into offscreen contexts at screen scale, timing the
    /// live layer with the current and the previous renderer, the pen-up commit and the page redraw.
    private static func benchmark(_ doc: DocumentModel) async -> [String] {
        let page = doc.page
        let scale = UIScreen.main.scale
        guard let overlay = context(page.size, scale), let content = context(page.size, scale) else {
            return ["Ink benchmark skipped: could not allocate drawing buffers."]
        }
        doc.select(.pen)
        let brush = doc.brush
        let buckets = [(1, 10), (31, 40), (71, 80)]
        var newFrame: [Int: [Double]] = [:], legacyFrame: [Int: [Double]] = [:]
        var commit: [Int: [Double]] = [:], redraw: [Int: [Double]] = [:]

        for n in 1...strokeCount {
            let row = Double((n - 1) % 20), column = Double((n - 1) / 20)
            let raw = scribble(x: 50 + column * 260, y: 60 + row * 62, samples: samplesPerStroke, seed: Double(n))
            let bucket = buckets.firstIndex { n >= $0.0 && n <= $0.1 }

            // Current renderer: incremental pieces + tail.
            var live = LiveStroke(brush: brush)
            var tailBounds = CGRect.null
            for chunk in stride(from: 0, to: raw.count, by: samplesPerFrame) {
                let samples = Array(raw[chunk..<min(raw.count, chunk + samplesPerFrame)])
                let predicted = predict(raw, at: chunk + samples.count)
                let t = measureMs {
                    var dirty = tailBounds
                    for p in samples { if let r = live.add(p) { dirty = dirty.union(r.cgRect) } }
                    tailBounds = live.bounds(of: live.tail(predicted: predicted))?.cgRect ?? .null
                    dirty = dirty.union(tailBounds).insetBy(dx: -1, dy: -1)
                    redrawOverlay(overlay, dirty) { LiveInkRenderer.draw(live, tail: live.tail(predicted: predicted), in: overlay, rect: dirty) }
                }
                if let bucket { newFrame[bucket, default: []].append(t) }
            }
            clear(overlay, page.size)

            // Previous renderer: rebuild and draw the whole stroke every frame.
            var drawn: [InkPoint] = []
            var lastPredicted: [InkPoint] = []
            for chunk in stride(from: 0, to: raw.count, by: samplesPerFrame) {
                let samples = Array(raw[chunk..<min(raw.count, chunk + samplesPerFrame)])
                let predicted = predict(raw, at: chunk + samples.count)
                let t = measureMs {
                    let before = legacyDirty(drawn, lastPredicted, brush)
                    drawn += samples
                    lastPredicted = predicted
                    let dirty = before.union(legacyDirty(drawn, predicted, brush))
                    redrawOverlay(overlay, dirty) { LiveInkRenderer.drawLegacy(raw: drawn, predicted: predicted, brush: brush, in: overlay) }
                }
                if let bucket { legacyFrame[bucket, default: []].append(t) }
            }
            clear(overlay, page.size)

            // Pen-up: commit to the model, then redraw that area of the page.
            let stroke = Stroke(brush: brush, points: live.finished())
            let c = measureMs { doc.addStroke(stroke) }
            let area = (stroke.bounds?.cgRect ?? .zero).insetBy(dx: -4, dy: -4)
            let r = measureMs { redrawOverlay(content, area) { doc.renderer.draw(doc.page, in: content, rasters: [:], visible: area) } }
            if let bucket { commit[bucket, default: []].append(c); redraw[bucket, default: []].append(r) }
            if n % 10 == 0 { await Task.yield() }
        }
        let full = measureMs { doc.renderer.draw(doc.page, in: content, rasters: [:]) }

        func stat(_ values: [Double]?) -> String {
            guard let s = PerfRecorder.summarize("", values ?? []) else { return "n/a" }
            return String(format: "%.2f/%.2f", s.p50, s.p95)
        }
        var out = ["Ink benchmark, ms p50/p95, \(strokeCount) strokes of \(samplesPerStroke) samples, \(Int(scale))x, \(samplesPerFrame) samples per frame:"]
        for (i, b) in buckets.enumerated() {
            out.append("strokes \(b.0)-\(b.1): live frame new \(stat(newFrame[i])), old \(stat(legacyFrame[i])); "
                + "pen-up commit \(stat(commit[i])); stroke-area redraw \(stat(redraw[i]))")
        }
        out.append(String(format: "Full page redraw at %d strokes: %.1f ms. Frame budget at 120 Hz: 8.3 ms.", strokeCount, full))
        return out
    }

    private static func context(_ size: Size, _ scale: CGFloat) -> CGContext? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Same space as a UIKit view: points, origin top-left.
        ctx.translateBy(x: 0, y: CGFloat(ctx.height))
        ctx.scaleBy(x: scale, y: -scale)
        return ctx
    }

    /// What UIKit does for `setNeedsDisplay(rect)` on a transparent view: clip, clear, redraw.
    private static func redrawOverlay(_ ctx: CGContext, _ rect: CGRect, _ draw: () -> Void) {
        guard !rect.isNull else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.clear(rect)
        draw()
        ctx.restoreGState()
    }

    private static func clear(_ ctx: CGContext, _ size: Size) {
        ctx.clear(CGRect(x: 0, y: 0, width: size.width, height: size.height))
    }

    private static func legacyDirty(_ points: [InkPoint], _ predicted: [InkPoint], _ brush: Brush) -> CGRect {
        guard let r = Rect.bounding(points.suffix(4).map(\.location) + predicted.map(\.location)) else { return .null }
        let pad = max(brush.size, 8) + 4
        return r.cgRect.insetBy(dx: -pad, dy: -pad)
    }

    private static func measureMs(_ body: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        body()
        return (CACurrentMediaTime() - start) * 1000
    }

    /// Two predicted samples extrapolated from the last two real ones (like UIKit's predictions).
    private static func predict(_ raw: [InkPoint], at index: Int) -> [InkPoint] {
        guard index >= 2, index < raw.count else { return [] }
        let a = raw[index - 2], b = raw[index - 1]
        let d = b.location - a.location
        return [1.0, 2.0].map { InkPoint(b.location + d * $0, pressure: b.pressure, time: b.time) }
    }

    /// Fast handwriting-like scribble: loops moving right with varying pressure.
    static func scribble(x: Double, y: Double, samples: Int, seed: Double) -> [InkPoint] {
        (0..<samples).map { i in
            let t = Double(i)
            return InkPoint(InkbookCore.Point(x + t * 1.4 + 9 * sin(t * 0.55 + seed), y + 16 * sin(t * 0.31 + seed) + 4 * cos(t * 1.3)),
                            pressure: 0.45 + 0.35 * sin(t * 0.17 + seed), time: t / 240)
        }
    }

    private static func line(from a: InkbookCore.Point, to b: InkbookCore.Point, samples: Int = 40) -> [InkPoint] {
        (0..<samples).map { i in InkPoint(a + (b - a) * (Double(i) / Double(samples - 1)), pressure: 0.6) }
    }

    private static func wave(x: Double, y: Double, width: Double, samples: Int) -> [InkPoint] {
        (0..<samples).map { i in
            let f = Double(i) / Double(samples - 1)
            return InkPoint(InkbookCore.Point(x + f * width, y + 12 * sin(f * 12)), pressure: 0.5)
        }
    }
}
