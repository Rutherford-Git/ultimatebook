import UIKit
import InkbookCore

/// Draws a page (paper, vector layers, raster layers) into a CGContext in page-point space.
/// Shared by the live canvas, thumbnails and the PNGs sent to the agent.
@MainActor
final class PageRenderer {
    private let store: NotebookStore
    private var imageCache: [String: UIImage] = [:]
    private var pdfCache: [String: CGPDFDocument] = [:]

    init(store: NotebookStore) { self.store = store }

    func invalidateAssets() { imageCache.removeAll(); pdfCache.removeAll() }

    /// - Parameters:
    ///   - rasters: current bitmaps for raster layers (live, possibly unsaved).
    ///   - skipLayer: layer whose content the caller draws itself (e.g. the one being painted).
    func draw(_ page: Page, in ctx: CGContext, rasters: [UUID: CGImage], skipLayer: UUID? = nil) {
        drawPaper(page, in: ctx)
        for layer in page.layers where layer.isVisible && layer.id != skipLayer {
            drawLayer(layer, page: page, in: ctx, raster: rasters[layer.id])
        }
    }

    func drawLayer(_ layer: Layer, page: Page, in ctx: CGContext, raster: CGImage?) {
        ctx.saveGState()
        ctx.setAlpha(layer.opacity)
        ctx.setBlendMode(layer.blendMode.cgBlendMode)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        switch layer.kind {
        case .raster:
            if let raster {
                // CGImage origin is bottom-left; flip into the top-left page space.
                ctx.saveGState()
                ctx.translateBy(x: 0, y: page.size.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(raster, in: CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height))
                ctx.restoreGState()
            }
        case .vector, .agent:
            for element in layer.elements { draw(element, in: ctx) }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    func draw(_ element: Element, in ctx: CGContext) {
        switch element {
        case .stroke(let s): Self.drawStroke(s, in: ctx)
        case .highlight(let h):
            ctx.setFillColor(h.color.cgColor)
            ctx.fill(h.frame.cgRect)
        case .image(let img):
            guard let image = image(named: img.asset) else { return }
            UIGraphicsPushContext(ctx)
            image.draw(in: img.frame.cgRect)
            UIGraphicsPopContext()
        case .text(let t):
            UIGraphicsPushContext(ctx)
            if let bg = t.background {
                ctx.setFillColor(bg.cgColor)
                UIBezierPath(roundedRect: t.frame.cgRect, cornerRadius: 6).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: t.fontSize),
                .foregroundColor: UIColor(cgColor: t.color.cgColor),
            ]
            (t.text as NSString).draw(in: t.frame.cgRect.insetBy(dx: 6, dy: 6), withAttributes: attrs)
            UIGraphicsPopContext()
        }
    }

    /// Vector ink: per-segment widths follow pressure, joined with round caps.
    static func drawStroke(_ s: Stroke, in ctx: CGContext) {
        guard let first = s.points.first else { return }
        ctx.saveGState()
        ctx.setStrokeColor(s.brush.color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if s.brush.kind == .highlighter { ctx.setBlendMode(.multiply) }
        if s.points.count == 1 || s.brush.minSizeRatio >= 1 {
            // Constant width: one smooth path (also keeps translucent highlighters even).
            guard let path = BrushEngine.quadraticPath(s.points.map(\.location)) else { ctx.restoreGState(); return }
            ctx.setLineWidth(s.brush.size)
            ctx.move(to: path.start.cg)
            if path.segments.isEmpty { ctx.addLine(to: CGPoint(x: first.location.x + 0.01, y: first.location.y)) }
            for (c, e) in path.segments { ctx.addQuadCurve(to: e.cg, control: c.cg) }
            ctx.strokePath()
        } else {
            for (a, b) in zip(s.points, s.points.dropFirst()) {
                ctx.setLineWidth(BrushEngine.diameter(for: s.brush, pressure: (a.pressure + b.pressure) / 2))
                ctx.move(to: a.location.cg)
                ctx.addLine(to: b.location.cg)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    private func drawPaper(_ page: Page, in ctx: CGContext) {
        let bounds = CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
        let lineColor = UIColor(red: 0.66, green: 0.77, blue: 0.91, alpha: 1).cgColor
        func fill(_ c: RGBA) { ctx.setFillColor(c.cgColor); ctx.fill(bounds) }
        switch page.paper {
        case .blank(let c): fill(c)
        case .ruled(let c, let spacing), .grid(let c, let spacing):
            fill(c)
            ctx.setStrokeColor(lineColor); ctx.setLineWidth(0.6)
            for y in stride(from: spacing, to: page.size.height, by: spacing) {
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: page.size.width, y: y))
            }
            if case .grid = page.paper {
                for x in stride(from: spacing, to: page.size.width, by: spacing) {
                    ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: page.size.height))
                }
            }
            ctx.strokePath()
        case .dotted(let c, let spacing):
            fill(c)
            ctx.setFillColor(lineColor)
            for y in stride(from: spacing, to: page.size.height, by: spacing) {
                for x in stride(from: spacing, to: page.size.width, by: spacing) {
                    ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                }
            }
        case .asset(let name, let pdfPage):
            fill(.white)
            if let pdfPage, let doc = pdf(named: name), let pdfPageRef = doc.page(at: pdfPage + 1) {
                ctx.saveGState()
                let box = pdfPageRef.getBoxRect(.cropBox)
                ctx.translateBy(x: 0, y: page.size.height)
                ctx.scaleBy(x: page.size.width / box.width, y: -page.size.height / box.height)
                ctx.translateBy(x: -box.minX, y: -box.minY)
                ctx.drawPDFPage(pdfPageRef)
                ctx.restoreGState()
            } else if let image = image(named: name) {
                UIGraphicsPushContext(ctx); image.draw(in: bounds); UIGraphicsPopContext()
            }
        }
    }

    private func image(named name: String) -> UIImage? {
        if let cached = imageCache[name] { return cached }
        guard let data = try? store.assetData(named: name), let image = UIImage(data: data) else { return nil }
        imageCache[name] = image
        return image
    }

    private func pdf(named name: String) -> CGPDFDocument? {
        if let cached = pdfCache[name] { return cached }
        guard let data = try? store.assetData(named: name), let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider) else { return nil }
        pdfCache[name] = doc
        return doc
    }

    /// PNG of the whole page with the long edge at most `maxPixels` (for thumbnails and the agent).
    func png(of page: Page, rasters: [UUID: CGImage], maxPixels: Int) -> Data {
        let scale = CGFloat(maxPixels) / max(page.size.width, page.size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(scale, 2)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: page.size.width, height: page.size.height), format: format)
        return renderer.pngData { self.draw(page, in: $0.cgContext, rasters: rasters) }
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

extension InkbookCore.Point {
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

extension InkbookCore.Rect {
    var cgRect: CGRect { CGRect(x: minX, y: minY, width: size.width, height: size.height) }
}

extension BlendMode {
    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        }
    }
}
