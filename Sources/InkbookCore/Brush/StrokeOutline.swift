import Foundation

/// Converts a pressure-sampled stroke into a filled outline, so width varies smoothly along
/// the stroke (like a fountain pen) instead of being stitched from round-capped segments.
public enum StrokeOutline {
    /// Segments used for a half-circle cap.
    static let capSegments = 8

    public static func outline(for stroke: Stroke) -> [PathCommand] {
        let pts = dedupe(stroke.points)
        guard let first = pts.first else { return [] }
        let radii = pts.map { BrushEngine.diameter(for: stroke.brush, pressure: $0.pressure) / 2 }
        if pts.count == 1 { return circle(center: first.location, radius: radii[0]) }

        var left: [Point] = [], right: [Point] = []
        for i in pts.indices {
            let prev = pts[max(0, i - 1)].location, next = pts[min(pts.count - 1, i + 1)].location
            let n = normal(from: prev, to: next)
            left.append(pts[i].location + n * radii[i])
            right.append(pts[i].location - n * radii[i])
        }
        var path: [PathCommand] = [.move(left[0])]
        path += left.dropFirst().map { .line($0) }
        path += cap(center: pts[pts.count - 1].location, from: left[left.count - 1], radius: radii[radii.count - 1])
        path += right.reversed().map { .line($0) }
        path += cap(center: pts[0].location, from: right[0], radius: radii[0])
        path.append(.close)
        return path
    }

    /// Unit normal (left-hand) of the direction a→b; falls back to +y for a zero-length step.
    static func normal(from a: Point, to b: Point) -> Point {
        let d = b - a
        let len = (d.x * d.x + d.y * d.y).squareRoot()
        guard len > 1e-9 else { return Point(0, 1) }
        return Point(-d.y / len, d.x / len)
    }

    /// Half circle around `center` starting at `from`, turning to the opposite side.
    static func cap(center: Point, from: Point, radius: Double) -> [PathCommand] {
        let start = atan2(from.y - center.y, from.x - center.x)
        return (1...capSegments).map { i in
            let a = start - Double.pi * Double(i) / Double(capSegments)
            return .line(Point(center.x + radius * cos(a), center.y + radius * sin(a)))
        }
    }

    static func circle(center: Point, radius: Double) -> [PathCommand] {
        let n = capSegments * 2
        var path: [PathCommand] = [.move(Point(center.x + radius, center.y))]
        for i in 1..<n {
            let a = 2 * Double.pi * Double(i) / Double(n)
            path.append(.line(Point(center.x + radius * cos(a), center.y + radius * sin(a))))
        }
        path.append(.close)
        return path
    }

    /// Drops consecutive duplicates, which would give undefined normals.
    static func dedupe(_ points: [InkPoint]) -> [InkPoint] {
        var out: [InkPoint] = []
        for p in points where out.last.map({ $0.location.distance(to: p.location) > 1e-6 }) ?? true {
            out.append(p)
        }
        return out
    }
}
