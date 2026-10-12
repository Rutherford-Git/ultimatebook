import Foundation

/// Page-space point (points, origin top-left, y down).
public struct Point: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public func distance(to other: Point) -> Double { hypot(other.x - x, other.y - y) }
    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    public static func * (a: Point, s: Double) -> Point { Point(a.x * s, a.y * s) }
}

public struct Size: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }

    /// US-letter-like portrait page used by Goodnotes ("letter" template, 1122 x 1452 pt).
    public static let letter = Size(1122, 1452)
}

public struct Rect: Codable, Hashable, Sendable {
    public var origin: Point
    public var size: Size
    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = Point(x, y); size = Size(width, height)
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    public func intersects(_ other: Rect) -> Bool {
        minX <= other.maxX && other.minX <= maxX && minY <= other.maxY && other.minY <= maxY
    }

    /// Smallest rect containing all points, or nil for an empty sequence.
    public static func bounding(_ points: some Sequence<Point>) -> Rect? {
        var it = points.makeIterator()
        guard let first = it.next() else { return nil }
        var lo = first, hi = first
        while let p = it.next() {
            lo = Point(min(lo.x, p.x), min(lo.y, p.y))
            hi = Point(max(hi.x, p.x), max(hi.y, p.y))
        }
        return Rect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }
}

/// sRGB color with straight (non-premultiplied) alpha, components 0...1.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let highlighterYellow = RGBA(1, 0.92, 0.23, 0.35)

    /// Parses `#RRGGBB` or `#RRGGBBAA`; returns nil for anything else.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        r = Double((v >> (16 + shift)) & 0xFF) / 255
        g = Double((v >> (8 + shift)) & 0xFF) / 255
        b = Double((v >> shift) & 0xFF) / 255
        a = hasAlpha ? Double(v & 0xFF) / 255 : 1
    }

    public var hex: String {
        let c = [r, g, b, a].map { Int(($0 * 255).rounded()).clamped(0, 255) }
        return String(format: "#%02X%02X%02X%02X", c[0], c[1], c[2], c[3])
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
