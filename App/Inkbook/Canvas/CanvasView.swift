import SwiftUI
import UIKit
import InkbookCore

/// Zoomable page canvas. Apple Pencil draws (coalesced touches for full 240 Hz fidelity);
/// fingers pan and pinch-zoom via the scroll view when "Pencil only" is on.
struct CanvasView: UIViewRepresentable {
    @ObservedObject var document: DocumentModel

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 0.5
        scroll.maximumZoomScale = 6
        scroll.backgroundColor = .systemGray5
        scroll.delegate = context.coordinator
        let surface = DrawingSurface(document: document)
        scroll.addSubview(surface)
        context.coordinator.surface = surface
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let surface = context.coordinator.surface else { return }
        let size = document.page.size
        if surface.bounds.size != CGSize(width: size.width, height: size.height) {
            surface.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            scroll.contentSize = surface.frame.size
            let fit = scroll.bounds.width > 0 ? scroll.bounds.width / size.width : 1
            scroll.zoomScale = fit
        }
        surface.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var surface: DrawingSurface?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            view?.contentScaleFactor = UIScreen.main.scale * scale   // re-render crisply after zoom
            view?.setNeedsDisplay()
        }
    }
}

/// Renders the page and captures strokes in page-point coordinates.
final class DrawingSurface: UIView {
    private let document: DocumentModel
    private var livePoints: [InkPoint] = []
    private var liveStart: TimeInterval = 0
    private var dabCarry = 0.0
    private var paintedUpTo = 0

    init(document: DocumentModel) {
        self.document = document
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        backgroundColor = .white
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        MainActor.assumeIsolated {
            let renderer = document.renderer
            renderer.draw(document.page, in: ctx, rasters: document.rasterImages)
            if !livePoints.isEmpty, !document.tool.isRaster, document.tool != .eraser {
                PageRenderer.drawStroke(Stroke(brush: document.brush, points: livePoints), in: ctx)
            }
        }
    }

    // MARK: Touches

    private func accepts(_ touch: UITouch) -> Bool {
        MainActor.assumeIsolated { !document.pencilOnly || touch.type == .pencil }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, accepts(touch) else { return super.touchesBegan(touches, with: event) }
        livePoints = []
        dabCarry = 0
        paintedUpTo = 0
        liveStart = touch.timestamp
        MainActor.assumeIsolated {
            if document.tool.isRaster || (document.tool == .eraser && document.activeLayer?.kind == .raster) {
                document.beginEdit(rasterLayer: document.activeLayerID)
            } else if document.tool == .eraser {
                document.beginEdit()
            }
        }
        append(touches: event?.coalescedTouches(for: touch) ?? [touch])
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, accepts(touch) else { return super.touchesMoved(touches, with: event) }
        append(touches: event?.coalescedTouches(for: touch) ?? [touch])
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, accepts(touch) else { return super.touchesEnded(touches, with: event) }
        append(touches: event?.coalescedTouches(for: touch) ?? [touch])
        commit()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        livePoints = []
        setNeedsDisplay()
    }

    private func append(touches: [UITouch]) {
        for t in touches {
            let p = t.preciseLocation(in: self)
            let pressure = t.type == .pencil ? Double(t.force / max(t.maximumPossibleForce, 0.001)) : 0.6
            let tilt = t.type == .pencil ? Double(1 - t.altitudeAngle / (.pi / 2)) : 0
            livePoints.append(InkPoint(InkbookCore.Point(p.x, p.y), pressure: pressure, tilt: tilt, time: t.timestamp - liveStart))
        }
        MainActor.assumeIsolated { paintIncrementally() }
        setNeedsDisplay()
    }

    @MainActor private func paintIncrementally() {
        let tool = document.tool
        if tool == .eraser, document.activeLayer?.kind != .raster, let last = livePoints.last {
            document.eraseStrokes(at: last.location, radius: document.brush.size / 2)
            return
        }
        guard tool.isRaster || tool == .eraser, let layer = document.activeLayer, layer.kind == .raster, !layer.isLocked,
              let bitmap = document.bitmap(for: layer, on: document.page) else { return }
        let start = max(0, paintedUpTo - 1)
        let dabs = BrushEngine.dabs(along: Array(livePoints[start...]), brush: document.brush, carry: &dabCarry)
        bitmap.stamp(dabs, brush: document.brush)
        paintedUpTo = livePoints.count
    }

    private func commit() {
        MainActor.assumeIsolated {
            defer { livePoints = []; setNeedsDisplay() }
            guard !document.tool.isRaster, document.tool != .eraser, document.tool != .lasso, !livePoints.isEmpty else {
                document.scheduleSave(); return
            }
            let smoothed = BrushEngine.simplify(BrushEngine.smooth(livePoints, strength: 0.5), minDistance: 0.6)
            document.addStroke(Stroke(brush: document.brush, points: smoothed))
        }
    }
}
