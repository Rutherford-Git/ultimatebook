import UIKit
import InkbookCore

/// Procreate-style paint surface for one raster layer: an RGBA bitmap at `scale` x page size.
/// Brush dabs from `BrushEngine.dabs` are stamped as radial-gradient discs.
@MainActor
final class RasterLayerBitmap {
    let layerID: UUID
    let pageSize: Size
    let scale: CGFloat
    private let context: CGContext
    private(set) var isDirty = false

    init?(layerID: UUID, pageSize: Size, scale: CGFloat = 2, png: Data?) {
        self.layerID = layerID; self.pageSize = pageSize; self.scale = scale
        let width = Int(pageSize.width * scale), height = Int(pageSize.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context = ctx
        if let png, let image = UIImage(data: png)?.cgImage {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Page space: points, origin top-left.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
    }

    private var cachedImage: CGImage?

    /// Current pixels. Cached until the next change, so several redraws in a row share one copy.
    var image: CGImage? {
        if let cachedImage { return cachedImage }
        cachedImage = context.makeImage()
        return cachedImage
    }

    func pngData() -> Data? {
        guard let image else { return nil }
        return UIImage(cgImage: image).pngData()
    }

    /// Stamps dabs. Eraser uses `.clear` so it removes paint without affecting other layers.
    func stamp(_ dabs: [BrushEngine.Dab], brush: Brush) {
        guard !dabs.isEmpty else { return }
        isDirty = true
        cachedImage = nil
        context.saveGState()
        context.setBlendMode(brush.kind == .eraser ? .clear : .normal)
        for dab in dabs { Self.draw(dab, brush: brush, in: context) }
        context.restoreGState()
    }

    /// Draws one dab exactly as it is stamped (shared with the live paint preview).
    static func draw(_ dab: BrushEngine.Dab, brush: Brush, in ctx: CGContext) {
        let color = brush.color
        let r = dab.diameter / 2
        let rect = CGRect(x: dab.center.x - r, y: dab.center.y - r, width: dab.diameter, height: dab.diameter)
        if brush.softness <= 0.01 || brush.kind == .eraser {
            ctx.setFillColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: dab.opacity))
            ctx.fillEllipse(in: rect)
        } else {
            let inner = CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: dab.opacity)
            let outer = CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 0)
            let hard = max(0, 1 - brush.softness)
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [inner, inner, outer] as CFArray,
                                            locations: [0, hard, 1]) else { return }
            ctx.drawRadialGradient(gradient, startCenter: dab.center.cg, startRadius: 0,
                                   endCenter: dab.center.cg, endRadius: r, options: [])
        }
    }

    func markSaved() { isDirty = false }
    func markUnsaved() { isDirty = true }

    /// Snapshot for undo.
    func snapshot() -> CGImage? { image }

    func restore(_ snapshot: CGImage?) {
        let w = CGFloat(context.width), h = CGFloat(context.height)
        context.saveGState()
        context.concatenate(context.ctm.inverted())   // back to device pixels
        context.clear(CGRect(x: 0, y: 0, width: w, height: h))
        if let snapshot { context.draw(snapshot, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        context.restoreGState()
        isDirty = true
        cachedImage = nil
    }
}
