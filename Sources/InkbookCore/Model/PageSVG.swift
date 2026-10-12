import Foundation

/// Renders a page's vector content to SVG (export, previews, and platform-independent tests).
/// Raster layers and asset backgrounds are embedded only when `resolveData` supplies their bytes.
public enum PageSVG {
    public static func render(_ page: Page, resolveData: (_ assetOrLayer: String) -> (Data, mime: String)? = { _ in nil }) -> String {
        let w = fmt(page.size.width), h = fmt(page.size.height)
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(w) \(h)\" width=\"\(w)\" height=\"\(h)\">"
        out += paper(page, resolveData: resolveData)
        for layer in page.layers where layer.isVisible {
            out += "<g opacity=\"\(fmt(layer.opacity))\" data-layer=\"\(layer.kind.rawValue)\">"
            if layer.kind == .raster, let (data, mime) = resolveData("raster:\(layer.id.uuidString)") {
                out += image(Rect(x: 0, y: 0, width: page.size.width, height: page.size.height), data, mime)
            }
            for element in layer.elements { out += svg(element, resolveData: resolveData) }
            out += "</g>"
        }
        return out + "</svg>"
    }

    static func paper(_ page: Page, resolveData: (String) -> (Data, mime: String)?) -> String {
        let full = "<rect width=\"100%\" height=\"100%\" fill=\"%@\"/>"
        func lines(_ color: RGBA, _ spacing: Double, vertical: Bool) -> String {
            var s = ""
            var y = spacing
            while y < page.size.height {
                s += "<line x1=\"0\" y1=\"\(fmt(y))\" x2=\"\(fmt(page.size.width))\" y2=\"\(fmt(y))\" stroke=\"#A9C4E8\" stroke-width=\"0.6\"/>"
                y += spacing
            }
            if vertical {
                var x = spacing
                while x < page.size.width {
                    s += "<line x1=\"\(fmt(x))\" y1=\"0\" x2=\"\(fmt(x))\" y2=\"\(fmt(page.size.height))\" stroke=\"#A9C4E8\" stroke-width=\"0.6\"/>"
                    x += spacing
                }
            }
            return full.replacingOccurrences(of: "%@", with: css(color)) + s
        }
        switch page.paper {
        case .blank(let c): return full.replacingOccurrences(of: "%@", with: css(c))
        case .ruled(let c, let s): return lines(c, s, vertical: false)
        case .grid(let c, let s): return lines(c, s, vertical: true)
        case .dotted(let c, let s):
            var dots = full.replacingOccurrences(of: "%@", with: css(c))
            var y = s
            while y < page.size.height {
                var x = s
                while x < page.size.width { dots += "<circle cx=\"\(fmt(x))\" cy=\"\(fmt(y))\" r=\"1\" fill=\"#A9C4E8\"/>"; x += s }
                y += s
            }
            return dots
        case .asset(let name, _):
            let base = full.replacingOccurrences(of: "%@", with: "#FFFFFF")
            guard let (data, mime) = resolveData(name), mime.hasPrefix("image/") else { return base }
            return base + image(Rect(x: 0, y: 0, width: page.size.width, height: page.size.height), data, mime)
        }
    }

    static func svg(_ element: Element, resolveData: (String) -> (Data, mime: String)?) -> String {
        switch element {
        case .stroke(let s) where s.usesOutline:
            return "<path d=\"\(pathData(StrokeOutline.outline(for: s)))\" fill=\"\(css(s.brush.color))\" fill-opacity=\"\(fmt(s.brush.color.a))\"/>"
        case .shape(let shape):
            return "<path d=\"\(pathData(shape.path))\" fill=\"\(css(shape.color))\" fill-opacity=\"\(fmt(shape.color.a))\" fill-rule=\"nonzero\"/>"
        case .stroke(let s):
            guard let path = BrushEngine.quadraticPath(s.points.map(\.location)) else { return "" }
            var d = "M\(fmt(path.start.x)),\(fmt(path.start.y))"
            if path.segments.isEmpty { d += " l0.01,0" }   // dot
            for (c, e) in path.segments { d += " Q\(fmt(c.x)),\(fmt(c.y)) \(fmt(e.x)),\(fmt(e.y))" }
            return "<path d=\"\(d)\" fill=\"none\" stroke=\"\(css(s.brush.color))\" stroke-opacity=\"\(fmt(s.brush.color.a))\" "
                + "stroke-width=\"\(fmt(s.brush.size))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
                + (s.brush.dash.map { " stroke-dasharray=\"\($0.map { fmt($0 * s.brush.size) }.joined(separator: " "))\"" } ?? "")
                + "/>"
        case .text(let t):
            var s = ""
            if let bg = t.background {
                s += "<rect x=\"\(fmt(t.frame.minX))\" y=\"\(fmt(t.frame.minY))\" width=\"\(fmt(t.frame.size.width))\" "
                    + "height=\"\(fmt(t.frame.size.height))\" rx=\"6\" fill=\"\(css(bg))\" fill-opacity=\"\(fmt(bg.a))\"/>"
            }
            s += "<text x=\"\(fmt(t.frame.minX + 6))\" y=\"\(fmt(t.frame.minY + t.fontSize + 2))\" font-family=\"Helvetica, Arial, sans-serif\" "
                + "font-size=\"\(fmt(t.fontSize))\" fill=\"\(css(t.color))\">"
            for (i, line) in t.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                s += "<tspan x=\"\(fmt(t.frame.minX + 6))\" dy=\"\(i == 0 ? "0" : fmt(t.fontSize * 1.25))\">\(escape(String(line)))</tspan>"
            }
            return s + "</text>"
        case .image(let i):
            guard let (data, mime) = resolveData(i.asset) else { return "" }
            return image(i.frame, data, mime)
        case .highlight(let h):
            return "<rect x=\"\(fmt(h.frame.minX))\" y=\"\(fmt(h.frame.minY))\" width=\"\(fmt(h.frame.size.width))\" "
                + "height=\"\(fmt(h.frame.size.height))\" fill=\"\(css(h.color))\" fill-opacity=\"\(fmt(h.color.a))\"/>"
        }
    }

    static func pathData(_ path: [PathCommand]) -> String {
        path.map { c -> String in
            switch c {
            case .move(let p): "M\(fmt(p.x)),\(fmt(p.y))"
            case .line(let p): "L\(fmt(p.x)),\(fmt(p.y))"
            case .quad(let c, let p): "Q\(fmt(c.x)),\(fmt(c.y)) \(fmt(p.x)),\(fmt(p.y))"
            case .cubic(let c1, let c2, let p): "C\(fmt(c1.x)),\(fmt(c1.y)) \(fmt(c2.x)),\(fmt(c2.y)) \(fmt(p.x)),\(fmt(p.y))"
            case .close: "Z"
            }
        }.joined(separator: " ")
    }

    static func image(_ frame: Rect, _ data: Data, _ mime: String) -> String {
        "<image x=\"\(fmt(frame.minX))\" y=\"\(fmt(frame.minY))\" width=\"\(fmt(frame.size.width))\" height=\"\(fmt(frame.size.height))\" "
            + "preserveAspectRatio=\"none\" href=\"data:\(mime);base64,\(data.base64EncodedString())\"/>"
    }

    static func css(_ c: RGBA) -> String { String(c.hex.prefix(7)) }

    static func fmt(_ v: Double) -> String {
        let s = String(format: "%.2f", v)
        var t = s
        while t.contains("."), t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t == "-0" ? "0" : t
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// MIME type from magic bytes (PNG, JPEG, PDF), or nil.
    public static func mimeType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if data.starts(with: Data("%PDF".utf8)) { return "application/pdf" }
        return nil
    }
}
