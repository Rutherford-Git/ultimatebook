import Foundation

/// One input sample from Apple Pencil (or finger). Pressure/tilt are normalized 0...1.
public struct InkPoint: Codable, Hashable, Sendable {
    public var location: Point
    public var pressure: Double
    public var tilt: Double
    /// Seconds since the stroke began.
    public var time: Double

    public init(_ location: Point, pressure: Double = 1, tilt: Double = 0, time: Double = 0) {
        self.location = location; self.pressure = pressure; self.tilt = tilt; self.time = time
    }
}

public enum BrushKind: String, Codable, Sendable, CaseIterable {
    case pen          // vector ink, pressure-modulated width
    case highlighter  // vector, flat width, translucent, drawn under ink
    case pencil       // raster, textured dabs
    case airbrush     // raster, soft dabs
    case marker       // raster, hard round dabs
    case eraser       // raster: clears pixels; vector: removes whole strokes
}

public struct Brush: Codable, Hashable, Sendable {
    public var kind: BrushKind
    public var color: RGBA
    /// Nominal diameter in points at pressure 1.
    public var size: Double
    /// Fraction of `size` reached at pressure 0 (pressure sensitivity; 1 = none).
    public var minSizeRatio: Double
    /// Distance between raster dabs as a fraction of the current diameter.
    public var spacing: Double
    /// 0 = hard edge, 1 = fully soft (raster brushes).
    public var softness: Double
    /// Dash pattern as on/off lengths in multiples of `size`; nil = solid.
    public var dash: [Double]?

    public init(kind: BrushKind, color: RGBA, size: Double,
                minSizeRatio: Double = 0.35, spacing: Double = 0.15, softness: Double = 0, dash: [Double]? = nil) {
        self.kind = kind; self.color = color; self.size = size
        self.minSizeRatio = minSizeRatio; self.spacing = spacing; self.softness = softness; self.dash = dash
    }

    public var isRaster: Bool { [.pencil, .airbrush, .marker].contains(kind) }

    public static let pen = Brush(kind: .pen, color: .black, size: 2.5)
    public static let highlighter = Brush(kind: .highlighter, color: .highlighterYellow, size: 18, minSizeRatio: 1)
}

/// A vector stroke. Geometry is the smoothed input polyline; renderers build curves from it.
public struct Stroke: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var brush: Brush
    public var points: [InkPoint]

    public init(id: UUID = UUID(), brush: Brush, points: [InkPoint]) {
        self.id = id; self.brush = brush; self.points = points
    }

    /// Pressure-sensitive solid pens render as a filled variable-width outline; constant-width,
    /// dashed and highlighter strokes render as a stroked centerline.
    public var usesOutline: Bool {
        brush.kind == .pen && brush.minSizeRatio < 1 && brush.dash == nil
    }

    public var bounds: Rect? {
        guard let r = Rect.bounding(points.map(\.location)) else { return nil }
        let pad = brush.size / 2
        return Rect(x: r.minX - pad, y: r.minY - pad, width: r.size.width + 2 * pad, height: r.size.height + 2 * pad)
    }
}

public struct TextBox: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var frame: Rect
    public var text: String
    public var fontSize: Double
    public var color: RGBA
    /// Translucent fill behind the text (used for agent sticky notes); nil = none.
    public var background: RGBA?

    public init(id: UUID = UUID(), frame: Rect, text: String, fontSize: Double = 18,
                color: RGBA = .black, background: RGBA? = nil) {
        self.id = id; self.frame = frame; self.text = text
        self.fontSize = fontSize; self.color = color; self.background = background
    }
}

public struct PlacedImage: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var frame: Rect
    /// File name inside the notebook's `assets/` directory.
    public var asset: String

    public init(id: UUID = UUID(), frame: Rect, asset: String) {
        self.id = id; self.frame = frame; self.asset = asset
    }
}

/// One drawing command of a filled outline.
public enum PathCommand: Codable, Hashable, Sendable {
    case move(Point)
    case line(Point)
    case quad(control: Point, to: Point)
    case cubic(control1: Point, control2: Point, to: Point)
    case close

    /// Every coordinate the command references (for bounds and hit-testing).
    public var points: [Point] {
        switch self {
        case .move(let p), .line(let p): [p]
        case .quad(let c, let p): [c, p]
        case .cubic(let c1, let c2, let p): [c1, c2, p]
        case .close: []
        }
    }

    public func translated(by d: Point) -> PathCommand {
        switch self {
        case .move(let p): .move(p + d)
        case .line(let p): .line(p + d)
        case .quad(let c, let p): .quad(control: c + d, to: p + d)
        case .cubic(let c1, let c2, let p): .cubic(control1: c1 + d, control2: c2 + d, to: p + d)
        case .close: .close
        }
    }
}

/// Filled outline with nonzero winding: imported fountain-pen ink and other exact shapes.
public struct FilledShape: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: [PathCommand]
    public var color: RGBA

    public init(id: UUID = UUID(), path: [PathCommand], color: RGBA) {
        self.id = id; self.path = path; self.color = color
    }

    public var bounds: Rect? { Rect.bounding(path.flatMap(\.points)) }
}

/// Filled translucent rectangle, e.g. an agent highlight over a region.
public struct HighlightRegion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var frame: Rect
    public var color: RGBA
    public init(id: UUID = UUID(), frame: Rect, color: RGBA = .highlighterYellow) {
        self.id = id; self.frame = frame; self.color = color
    }
}

public enum Element: Codable, Hashable, Sendable, Identifiable {
    case stroke(Stroke)
    case text(TextBox)
    case image(PlacedImage)
    case highlight(HighlightRegion)
    case shape(FilledShape)

    public var id: UUID {
        switch self {
        case .stroke(let s): s.id
        case .text(let t): t.id
        case .image(let i): i.id
        case .highlight(let h): h.id
        case .shape(let s): s.id
        }
    }

    /// Axis-aligned bounds in page points (nil for empty geometry).
    public var bounds: Rect? {
        switch self {
        case .stroke(let s): s.bounds
        case .text(let t): t.frame
        case .image(let i): i.frame
        case .highlight(let h): h.frame
        case .shape(let s): s.bounds
        }
    }

    /// Points evenly spread over the element, used by lasso selection: ink is resampled by arc
    /// length (so slowly written parts don't outweigh fast ones), boxes use a 3×3 grid.
    public var samplePoints: [Point] {
        switch self {
        case .stroke(let s): return Self.resample(s.points.map(\.location), count: 24)
        case .shape(let s): return Self.resample(s.path.flatMap(\.points), count: 24)
        case .text, .image, .highlight:
            guard let r = bounds else { return [] }
            return [0.1, 0.5, 0.9].flatMap { fy in
                [0.1, 0.5, 0.9].map { fx in Point(r.minX + r.size.width * fx, r.minY + r.size.height * fy) }
            }
        }
    }

    /// `count` points evenly spaced along a polyline (endpoints included).
    static func resample(_ pts: [Point], count: Int) -> [Point] {
        guard pts.count > 1, count > 1 else { return pts }
        var cumulative = [0.0]
        for (a, b) in zip(pts, pts.dropFirst()) { cumulative.append(cumulative[cumulative.count - 1] + a.distance(to: b)) }
        let total = cumulative[cumulative.count - 1]
        guard total > 0 else { return [pts[0]] }
        var out: [Point] = []
        var seg = 0
        for i in 0..<count {
            let target = total * Double(i) / Double(count - 1)
            while seg < pts.count - 2, cumulative[seg + 1] < target { seg += 1 }
            let len = cumulative[seg + 1] - cumulative[seg]
            let t = len > 0 ? (target - cumulative[seg]) / len : 0
            out.append(pts[seg] + (pts[seg + 1] - pts[seg]) * t)
        }
        return out
    }

    public func translated(by d: Point) -> Element {
        func move(_ r: Rect) -> Rect { Rect(x: r.minX + d.x, y: r.minY + d.y, width: r.size.width, height: r.size.height) }
        switch self {
        case .stroke(var s):
            for i in s.points.indices { s.points[i].location = s.points[i].location + d }
            return .stroke(s)
        case .text(var t): t.frame = move(t.frame); return .text(t)
        case .image(var i): i.frame = move(i.frame); return .image(i)
        case .highlight(var h): h.frame = move(h.frame); return .highlight(h)
        case .shape(var s): s.path = s.path.map { $0.translated(by: d) }; return .shape(s)
        }
    }

    /// Copy with fresh identity (duplicate / paste).
    public func withNewID() -> Element {
        switch self {
        case .stroke(var s): s.id = UUID(); return .stroke(s)
        case .text(var t): t.id = UUID(); return .text(t)
        case .image(var i): i.id = UUID(); return .image(i)
        case .highlight(var h): h.id = UUID(); return .highlight(h)
        case .shape(var s): s.id = UUID(); return .shape(s)
        }
    }
}

public enum LayerKind: String, Codable, Sendable {
    /// Goodnotes-style: editable vector strokes, text, images.
    case vector
    /// Procreate-style: a bitmap stored as `raster/<layerId>.png` (page size x scale).
    case raster
    /// Vector layer that only the agent bridge writes to (after user approval).
    case agent
}

public enum BlendMode: String, Codable, Sendable, CaseIterable {
    case normal, multiply, screen, overlay
}

public struct Layer: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: LayerKind
    public var isVisible: Bool
    public var isLocked: Bool
    public var opacity: Double
    public var blendMode: BlendMode
    /// Vector content (empty for raster layers).
    public var elements: [Element]

    public init(id: UUID = UUID(), name: String, kind: LayerKind, isVisible: Bool = true,
                isLocked: Bool = false, opacity: Double = 1, blendMode: BlendMode = .normal,
                elements: [Element] = []) {
        self.id = id; self.name = name; self.kind = kind; self.isVisible = isVisible
        self.isLocked = isLocked; self.opacity = opacity; self.blendMode = blendMode
        self.elements = elements
    }
}

public enum Paper: Codable, Hashable, Sendable {
    case blank(RGBA)
    case ruled(RGBA, spacing: Double)
    case grid(RGBA, spacing: Double)
    case dotted(RGBA, spacing: Double)
    /// PDF or image background from `assets/` (PDF: 0-based page index).
    case asset(String, pdfPage: Int?)
}

public struct Page: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var size: Size
    public var paper: Paper
    /// Bottom-to-top draw order.
    public var layers: [Layer]
    /// Handwriting text recognized for this page (imported or on-device), keyed by nothing:
    /// a plain reading-order transcript the agent can read.
    public var recognizedText: String?

    public init(id: UUID = UUID(), size: Size = .letter, paper: Paper = .blank(.white),
                layers: [Layer]? = nil, recognizedText: String? = nil) {
        self.id = id; self.size = size; self.paper = paper
        self.layers = layers ?? [Layer(name: "Ink", kind: .vector)]
        self.recognizedText = recognizedText
    }

    public var agentLayerIndex: Int? { layers.firstIndex { $0.kind == .agent } }

    /// Returns the agent layer index, creating the layer on top when missing.
    public mutating func ensureAgentLayer() -> Int {
        if let i = agentLayerIndex { return i }
        layers.append(Layer(name: "Agent", kind: .agent))
        return layers.count - 1
    }

    /// All text the page carries: typed text boxes (in layer order) then recognized handwriting.
    public var allText: String {
        var parts: [String] = []
        for layer in layers where layer.isVisible {
            for case .text(let t) in layer.elements { parts.append(t.text) }
        }
        if let r = recognizedText, !r.isEmpty { parts.append(r) }
        return parts.joined(separator: "\n")
    }
}

/// How a notebook's cover looks in the library.
public enum NotebookCover: Codable, Hashable, Sendable {
    /// Solid cloth-style cover in one of the app's cover colors (index into the palette).
    case color(Int)
    /// A thumbnail of the first page (imported PDFs and Goodnotes notebooks).
    case firstPage

    public static let paletteCount = 8
}

public struct Notebook: Codable, Hashable, Sendable, Identifiable {
    public static let schemaVersion = 1

    public var id: UUID
    public var title: String
    public var created: Date
    public var modified: Date
    public var pages: [Page]
    public var cover: NotebookCover
    public var isFavorite: Bool

    public init(id: UUID = UUID(), title: String, pages: [Page] = [Page()], cover: NotebookCover = .color(0),
                isFavorite: Bool = false, created: Date = Date(), modified: Date = Date()) {
        self.id = id; self.title = title; self.pages = pages
        self.cover = cover; self.isFavorite = isFavorite
        self.created = created; self.modified = modified
    }

    private enum CodingKeys: String, CodingKey { case id, title, created, modified, pages, cover, isFavorite }

    /// Fields added after schema 1 shipped (`cover`, `isFavorite`) decode with defaults, so
    /// notebooks saved by earlier builds still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        created = try c.decode(Date.self, forKey: .created)
        modified = try c.decode(Date.self, forKey: .modified)
        pages = try c.decode([Page].self, forKey: .pages)
        cover = try c.decodeIfPresent(NotebookCover.self, forKey: .cover) ?? .color(0)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    /// The small summary the library shows, without the pages.
    public var info: NotebookInfo {
        NotebookInfo(id: id, title: title, modified: modified, cover: cover, isFavorite: isFavorite, pageCount: pages.count)
    }
}

/// Library summary of a notebook, stored as `info.json` next to the manifest so the library
/// does not decode every notebook's full content to list it.
public struct NotebookInfo: Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var modified: Date
    public var cover: NotebookCover
    public var isFavorite: Bool
    public var pageCount: Int
}
