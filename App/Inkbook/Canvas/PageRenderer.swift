import UIKit
import InkbookCore

/// Draws a page (paper, vector layers, raster layers) into a CGContext in page-point space.
/// Shared by the canvas, thumbnails, PDF export and the PNGs sent to the agent.
@MainActor
final class PageRenderer {
    private let store: NotebookStore
    private var imageCache: [String: UIImage] = [:]
    private var pdfCache: [String: CGPDFDocument] = [:]

    init(store: NotebookStore) { self.store = store }

    func invalidateAssets() { imageCache.removeAll(); pdfCache.removeAll() }

    /// - Parameters:
    ///   - rasters: current bitmaps for raster layers.
    ///   - skipElements: elements the caller draws itself (e.g. a selection being dragged).
    ///   - visible: only elements intersecting this page rect are drawn (dirty-rect redraws).
    func draw(_ page: Page, in ctx: CGContext, rasters: [UUID: CGImage],
              skipElements: Set<UUID> = [], visible: CGRect? = nil) {
        drawPaper(page, in: ctx)
        for layer in page.layers where layer.isVisible {
            drawLayer(layer, page: page, in: ctx, raster: rasters[layer.id], skipElements: skipElements, visible: visible)
        }
    }

    func drawLayer(_ layer: Layer, page: Page, in ctx: CGContext, raster: CGImage?,
                   skipElements: Set<UUID> = [], visible: CGRect? = nil) {
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
            for element in layer.elements where !skipElements.contains(element.id) {
                if let visible, let b = element.bounds, !b.cgRect.insetBy(dx: -2, dy: -2).intersects(visible) { continue }
                draw(element, in: ctx)
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    func draw(_ element: Element, in ctx: CGContext) {
        switch element {
        case .stroke(let s): Self.drawStroke(s, in: ctx)
        case .shape(let shape):
            ctx.saveGState()
            ctx.setFillColor(shape.color.cgColor)
            ctx.addPath(Self.cgPath(shape.path))
            ctx.fillPath(using: .winding)
            ctx.restoreGState()
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

    /// Pressure pens fill their variable-width outline; highlighters, dashed and constant-width
    /// strokes stroke a smooth centerline.
    static func drawStroke(_ s: Stroke, in ctx: CGContext) {
        guard let first = s.points.first else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if s.usesOutline {
            ctx.setFillColor(s.brush.color.cgColor)
            ctx.addPath(cgPath(StrokeOutline.outline(for: s)))
            ctx.fillPath(using: .winding)
            return
        }
        guard let path = BrushEngine.quadraticPath(s.points.map(\.location)) else { return }
        ctx.setStrokeColor(s.brush.color.cgColor)
        ctx.setLineCap(s.brush.dash == nil ? .round : .butt)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(s.brush.size)
        if let dash = s.brush.dash { ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0 * s.brush.size) }) }
        if s.brush.kind == .highlighter { ctx.setBlendMode(.multiply) }
        ctx.move(to: path.start.cg)
        if path.segments.isEmpty { ctx.addLine(to: CGPoint(x: first.location.x + 0.01, y: first.location.y)) }
        for (c, e) in path.segments { ctx.addQuadCurve(to: e.cg, control: c.cg) }
        ctx.strokePath()
    }

    static func cgPath(_ commands: [PathCommand]) -> CGPath {
        let path = CGMutablePath()
        for c in commands {
            switch c {
            case .move(let p): path.move(to: p.cg)
            case .line(let p): path.addLine(to: p.cg)
            case .quad(let c, let p): path.addQuadCurve(to: p.cg, control: c.cg)
            case .cubic(let c1, let c2, let p): path.addCurve(to: p.cg, control1: c1.cg, control2: c2.cg)
            case .close: path.closeSubpath()
            }
        }
        return path
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
                Self.drawPDFPage(pdfPageRef, in: ctx, size: CGSize(width: page.size.width, height: page.size.height))
            } else if let image = image(named: name) {
                UIGraphicsPushContext(ctx); image.draw(in: bounds); UIGraphicsPopContext()
            }
        }
    }

    /// Draws a PDF page (honoring its /Rotate) to fill `size` in a top-left-origin context.
    static func drawPDFPage(_ pdfPage: CGPDFPage, in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let target = CGRect(origin: .zero, size: size)
        let box = pdfPage.getBoxRect(.cropBox)
        let rotated = pdfPage.rotationAngle % 180 != 0
        let displayed = rotated ? CGSize(width: box.height, height: box.width) : box.size
        // getDrawingTransform never scales up, so scale explicitly to fill the page.
        let scale = min(size.width / max(displayed.width, 1), size.height / max(displayed.height, 1))
        ctx.translateBy(x: target.midX, y: target.midY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -displayed.width / 2, y: -displayed.height / 2)
        ctx.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayed),
                                                    rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(pdfPage)
        ctx.restoreGState()
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

    /// Image of the whole page with the long edge at most `maxPixels` (thumbnails, agent, recognition).
    func image(of page: Page, rasters: [UUID: CGImage], maxPixels: Int) -> UIImage {
        let scale = CGFloat(maxPixels) / max(page.size.width, page.size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(scale, 2)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: page.size.width, height: page.size.height), format: format)
        return renderer.image { self.draw(page, in: $0.cgContext, rasters: rasters) }
    }

    /// Ink only (vector strokes and shapes on non-agent layers) on white: input for handwriting
    /// recognition, so printed PDF/image text and agent notes are not transcribed as handwriting.
    func inkImage(of page: Page, maxPixels: Int) -> UIImage {
        let scale = CGFloat(maxPixels) / max(page.size.width, page.size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(scale, 3)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: page.size.width, height: page.size.height), format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height))
            for layer in page.layers where layer.kind == .vector && layer.isVisible {
                for element in layer.elements {
                    switch element {
                    case .stroke(let s) where s.brush.kind != .highlighter: draw(element, in: ctx.cgContext)
                    case .shape: draw(element, in: ctx.cgContext)
                    default: break
                    }
                }
            }
        }
    }

    func png(of page: Page, rasters: [UUID: CGImage], maxPixels: Int) -> Data {
        image(of: page, rasters: rasters, maxPixels: maxPixels).pngData() ?? Data()
    }

    /// Multi-page PDF of the notebook; vector content stays vector.
    func pdfData(of notebook: Notebook, rasters: (Page) -> [UUID: CGImage]) -> Data {
        let first = notebook.pages.first?.size ?? .letter
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: first.width, height: first.height))
        return renderer.pdfData { ctx in
            for page in notebook.pages {
                ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height), pageInfo: [:])
                draw(page, in: ctx.cgContext, rasters: rasters(page))
            }
        }
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

extension InkbookCore.Point {
    var cg: CGPoint { CGPoint(x: x, y: y) }
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
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
