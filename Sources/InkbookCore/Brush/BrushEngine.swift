import Foundation

/// Pure brush math shared by the vector ink renderer and the raster (Procreate-style) painter.
/// Kept free of UIKit/CoreGraphics so it is unit-tested on any platform.
public enum BrushEngine {
    /// Diameter for a sample: interpolates between `minSizeRatio * size` and `size`
    /// with an ease-out pressure curve (light touches still read as intentional).
    public static func diameter(for brush: Brush, pressure: Double) -> Double {
        let p = pressure.clamped(0, 1)
        let curved = 1 - (1 - p) * (1 - p)
        let lo = brush.size * brush.minSizeRatio.clamped(0, 1)
        return lo + (brush.size - lo) * curved
    }

    /// Exponential smoothing of raw input. `strength` 0 = raw, 0.9 = very smooth.
    /// Endpoints are preserved so strokes still start and end under the pencil tip.
    public static func smooth(_ points: [InkPoint], strength: Double) -> [InkPoint] {
        guard points.count > 2, strength > 0 else { return points }
        let k = strength.clamped(0, 0.95)
        var out = points
        var prev = points[0].location
        for i in 1..<(points.count - 1) {
            let p = points[i].location
            prev = prev * k + p * (1 - k)
            out[i].location = prev
        }
        return out
    }

    /// Drops samples closer than `minDistance` to the previously kept one (keeps last point).
    public static func simplify(_ points: [InkPoint], minDistance: Double) -> [InkPoint] {
        guard points.count > 2 else { return points }
        var out = [points[0]]
        for p in points.dropFirst().dropLast() where p.location.distance(to: out.last!.location) >= minDistance {
            out.append(p)
        }
        out.append(points[points.count - 1])
        return out
    }

    /// A raster stamp position.
    public struct Dab: Equatable, Sendable {
        public var center: Point
        public var diameter: Double
        public var opacity: Double
    }

    /// Evenly spaced dabs along a polyline (Procreate-style stamping). `carry` is the distance
    /// already travelled since the last dab of a previous call, so incremental rendering of a
    /// live stroke produces exactly the same dabs as rendering it all at once.
    public static func dabs(along points: [InkPoint], brush: Brush, carry: inout Double) -> [Dab] {
        guard let first = points.first else { return [] }
        var result: [Dab] = []
        if points.count == 1 {
            result.append(Dab(center: first.location, diameter: diameter(for: brush, pressure: first.pressure),
                              opacity: brush.color.a))
            return result
        }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let segment = a.location.distance(to: b.location)
            guard segment > 0 else { continue }
            var t = 0.0
            while true {
                let pressure = a.pressure + (b.pressure - a.pressure) * (t / segment)
                let step = max(0.5, diameter(for: brush, pressure: pressure) * brush.spacing.clamped(0.01, 4))
                let needed = step - carry
                if t + needed > segment {
                    carry += segment - t
                    break
                }
                t += needed
                carry = 0
                let f = t / segment
                let p = a.pressure + (b.pressure - a.pressure) * f
                result.append(Dab(center: a.location + (b.location - a.location) * f,
                                  diameter: diameter(for: brush, pressure: p),
                                  opacity: brush.color.a))
            }
        }
        return result
    }

    /// Quadratic midpoint-curve control points for rendering a smooth vector stroke:
    /// returns (start, [(control, end)]) where each segment is a quadratic Bézier.
    public static func quadraticPath(_ points: [Point]) -> (start: Point, segments: [(Point, Point)])? {
        guard let first = points.first else { return nil }
        guard points.count > 2 else {
            return (first, points.count == 2 ? [(first, points[1])] : [])
        }
        var segments: [(Point, Point)] = []
        for i in 1..<(points.count - 1) {
            let mid = (points[i] + points[i + 1]) * 0.5
            segments.append((points[i], mid))
        }
        segments.append((points[points.count - 1], points[points.count - 1]))
        return (first, segments)
    }

    /// Vector eraser: ids of strokes whose geometry passes within `radius` of `point`.
    public static func strokesHit(by point: Point, radius: Double, in elements: [Element]) -> [UUID] {
        elements.compactMap { element in
            guard case .stroke(let s) = element else { return nil }
            let reach = radius + s.brush.size / 2
            return s.points.contains { $0.location.distance(to: point) <= reach } ? s.id : nil
        }
    }
}
