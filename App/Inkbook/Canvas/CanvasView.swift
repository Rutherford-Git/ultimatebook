import SwiftUI
import UIKit
import InkbookCore

/// Zoomable page canvas. Apple Pencil draws; fingers pan and pinch-zoom (when "Pencil only" is on).
struct CanvasView: UIViewRepresentable {
    @ObservedObject var document: DocumentModel

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 0.5
        scroll.maximumZoomScale = 6
        scroll.backgroundColor = .systemGray5
        scroll.delaysContentTouches = false   // Pencil strokes start without the scroll view's delay
        scroll.delegate = context.coordinator
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let page = PageView(document: document)
        scroll.addSubview(page)
        context.coordinator.page = page
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let page = context.coordinator.page else { return }
        scroll.panGestureRecognizer.minimumNumberOfTouches = document.pencilOnly ? 1 : 2
        let size = CGSize(width: document.page.size.width, height: document.page.size.height)
        if page.bounds.size != size {
            scroll.zoomScale = 1
            page.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            if scroll.bounds.width > 0 { scroll.zoomScale = scroll.bounds.width / size.width }
            page.updateResolution(zoom: scroll.zoomScale)
        }
        page.sync()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var page: PageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { page }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            MainActor.assumeIsolated { page?.updateResolution(zoom: scale) }
        }
    }
}

/// Hosts the cached page content plus a lightweight overlay for whatever is in progress,
/// and turns touches into strokes, paint, erasing, lasso selection and selection moves.
final class PageView: UIView {
    private let document: DocumentModel
    private let content: PageContentView
    private let overlay: OverlayView

    private enum Mode { case idle, ink, raster, vectorErase, lasso, drag(start: CGPoint) }
    private var mode: Mode = .idle
    private var points: [InkPoint] = []
    private var predicted: [InkPoint] = []
    private var strokeStart: TimeInterval = 0
    private var dabCarry = 0.0
    private var paintedUpTo = 0
    private var paintedBounds: CGRect = .null
    private var lastSeenRevision = -1

    init(document: DocumentModel) {
        self.document = document
        content = PageContentView(document: document)
        overlay = OverlayView()
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 6
        for v in [content, overlay] as [UIView] {
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(v)
        }
        overlay.isUserInteractionEnabled = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.host = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
        overlay.frame = bounds
    }

    /// Backing-store resolution follows zoom, capped at ~16 MP so deep zoom cannot exhaust memory.
    func updateResolution(zoom: CGFloat) {
        let screen = window?.screen.scale ?? UIScreen.main.scale
        let area = max(bounds.width * bounds.height, 1)
        let scale = min(screen * zoom, (16_000_000 / area).squareRoot(), screen * 4)
        for v in [content, overlay] as [UIView] {
            v.contentScaleFactor = max(1, scale)
            v.setNeedsDisplay()
        }
    }

    /// Redraws whatever the document reports as changed since the last sync.
    func sync() {
        guard document.revision != lastSeenRevision else { return }
        lastSeenRevision = document.revision
        if let rect = document.takeDirtyRect() {
            if !rect.isNull { content.setNeedsDisplay(rect.insetBy(dx: -4, dy: -4)) }
        } else {
            content.setNeedsDisplay()
        }
        overlay.setNeedsDisplay()   // selection box may have moved
    }

    // MARK: Overlay state

    var liveStroke: Stroke? {
        guard case .ink = mode, !points.isEmpty else { return nil }
        return Stroke(brush: document.brush, points: points + predicted)
    }

    var livePaint: (points: [InkPoint], brush: Brush)? {
        guard case .raster = mode, document.tool != .eraser, !points.isEmpty else { return nil }
        return (points, document.brush)
    }

    var lassoPath: [CGPoint]? {
        guard case .lasso = mode else { return nil }
        return points.map { $0.location.cg }
    }

    var dragOffset: CGPoint? {
        guard case .drag(let start) = mode, let last = points.last else { return nil }
        return CGPoint(x: last.location.x - start.x, y: last.location.y - start.y)
    }

    var documentModel: DocumentModel { document }

    // MARK: Touches

    private func accepts(_ touch: UITouch) -> Bool { !document.pencilOnly || touch.type == .pencil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, accepts(touch) else { return super.touchesBegan(touches, with: event) }
        points = []; predicted = []
        dabCarry = 0; paintedUpTo = 0; paintedBounds = .null
        strokeStart = touch.timestamp
        let p = touch.preciseLocation(in: self)
        let layerKind = document.activeLayer?.kind

        switch document.tool {
        case .lasso:
            if let box = document.selectionBounds?.cgRect.insetBy(dx: -12, dy: -12), box.contains(p) {
                mode = .drag(start: p)
                content.skipElements = document.selection
                content.setNeedsDisplay(box)
            } else {
                document.clearSelection()
                mode = .lasso
            }
        case .eraser where layerKind == .raster:
            document.beginEdit(rasterLayer: document.activeLayerID)
            mode = .raster
        case .eraser:
            document.beginEdit()
            mode = .vectorErase
        case let t where t.isRaster:
            guard layerKind == .raster, document.activeLayer?.isLocked == false else { mode = .idle; return }
            document.beginEdit(rasterLayer: document.activeLayerID)
            mode = .raster
        default:
            mode = .ink
        }
        append(event?.coalescedTouches(for: touch) ?? [touch], predicted: event?.predictedTouches(for: touch) ?? [])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, accepts(touch) else { return super.touchesMoved(touches, with: event) }
        append(event?.coalescedTouches(for: touch) ?? [touch], predicted: event?.predictedTouches(for: touch) ?? [])
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, accepts(touch) else { return super.touchesEnded(touches, with: event) }
        append(event?.coalescedTouches(for: touch) ?? [touch], predicted: [])
        finish()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if case .raster = mode { document.rasterStrokeEnded(dirty: nil) }
        content.skipElements = []
        mode = .idle; points = []; predicted = []
        content.setNeedsDisplay()
        overlay.setNeedsDisplay()
    }

    private func sample(_ t: UITouch) -> InkPoint {
        let p = t.preciseLocation(in: self)
        let pressure = t.type == .pencil ? Double(t.force / max(t.maximumPossibleForce, 0.001)) : 0.6
        let tilt = t.type == .pencil ? Double(1 - t.altitudeAngle / (.pi / 2)) : 0
        return InkPoint(InkbookCore.Point(p), pressure: pressure, tilt: tilt, time: t.timestamp - strokeStart)
    }

    private func append(_ touches: [UITouch], predicted predictedTouches: [UITouch]) {
        let before = dirtyArea()
        points += touches.map(sample)
        predicted = predictedTouches.map(sample)

        switch mode {
        case .vectorErase:
            if let last = points.last { document.eraseStrokes(at: last.location, radius: document.brush.size / 2) }
        case .raster:
            paint()
        default:
            break
        }
        overlay.setNeedsDisplay(before.union(dirtyArea()))
    }

    /// Overlay area touched by the newest samples (and the previous prediction).
    private func dirtyArea() -> CGRect {
        var pts = points.suffix(4).map(\.location) + predicted.map(\.location)
        if case .drag = mode, let box = document.selectionBounds, let off = dragOffset {
            pts += [box.origin, InkbookCore.Point(box.maxX, box.maxY)].map { InkbookCore.Point($0.x + off.x, $0.y + off.y) }
        }
        guard let r = Rect.bounding(pts) else { return .null }
        let pad = max(document.brush.size, 8) + 4
        if case .drag = mode, let box = document.selectionBounds {
            return r.cgRect.union(box.cgRect).insetBy(dx: -pad, dy: -pad)   // old position too
        }
        return r.cgRect.insetBy(dx: -pad, dy: -pad)
    }

    /// Stamps new raster dabs into the layer bitmap. Painting is previewed by the overlay;
    /// erasing has no overlay preview, so the content view repaints the erased area.
    private func paint() {
        guard let layer = document.activeLayer, let bitmap = document.bitmap(for: layer, on: document.page) else { return }
        let start = max(0, paintedUpTo - 1)
        let dabs = BrushEngine.dabs(along: Array(points[start...]), brush: document.brush, carry: &dabCarry)
        paintedUpTo = points.count
        guard !dabs.isEmpty else { return }
        bitmap.stamp(dabs, brush: document.brush)
        let r = Rect.bounding(dabs.map(\.center))!.cgRect.insetBy(dx: -document.brush.size, dy: -document.brush.size)
        paintedBounds = paintedBounds.union(r)
        if document.tool == .eraser { content.setNeedsDisplay(r) }
    }

    private func finish() {
        defer {
            mode = .idle; points = []; predicted = []
            overlay.setNeedsDisplay()
        }
        switch mode {
        case .ink:
            guard !points.isEmpty else { return }
            let smoothed = BrushEngine.simplify(BrushEngine.smooth(points, strength: 0.5), minDistance: 0.6)
            document.addStroke(Stroke(brush: document.brush, points: smoothed))
        case .raster:
            document.rasterStrokeEnded(dirty: paintedBounds.isNull ? nil : Rect(x: paintedBounds.minX, y: paintedBounds.minY,
                                                                                 width: paintedBounds.width, height: paintedBounds.height))
        case .lasso:
            document.lassoSelect(points.map(\.location))
        case .drag:
            let offset = dragOffset ?? .zero
            content.skipElements = []
            if let box = document.selectionBounds { content.setNeedsDisplay(box.cgRect.insetBy(dx: -4, dy: -4)) }
            document.moveSelection(by: InkbookCore.Point(offset))
        case .vectorErase, .idle:
            break
        }
    }
}

/// Committed page content. UIKit keeps the rendered bitmap; only invalidated rects redraw.
final class PageContentView: UIView {
    private let document: DocumentModel
    var skipElements: Set<UUID> = []

    init(document: DocumentModel) {
        self.document = document
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .white
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let page = document.page
        document.renderer.draw(page, in: ctx, rasters: document.rasterImages(for: page),
                               skipElements: skipElements, visible: rect)
    }
}

/// In-progress feedback: live ink, live paint, lasso path, selection box and dragged selection.
final class OverlayView: UIView {
    weak var host: PageView?

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let host else { return }
        let document = host.documentModel

        if let stroke = host.liveStroke {
            PageRenderer.drawStroke(stroke, in: ctx)
        }
        if let (pts, brush) = host.livePaint {
            var carry = 0.0
            ctx.setFillColor(brush.color.cgColor)
            for dab in BrushEngine.dabs(along: pts, brush: brush, carry: &carry) {
                let r = dab.diameter / 2
                let box = CGRect(x: dab.center.x - r, y: dab.center.y - r, width: dab.diameter, height: dab.diameter)
                if box.intersects(rect) { ctx.fillEllipse(in: box) }
            }
        }
        if let lasso = host.lassoPath, lasso.count > 1 {
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.addLines(between: lasso)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let box = document.selectionBounds?.cgRect {
            let offset = host.dragOffset ?? .zero
            if host.dragOffset != nil {
                ctx.saveGState()
                ctx.translateBy(x: offset.x, y: offset.y)
                for element in document.selectedElements { document.renderer.draw(element, in: ctx) }
                ctx.restoreGState()
            }
            ctx.setStrokeColor(UIColor.systemBlue.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.stroke(box.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -8, dy: -8))
        }
    }
}
