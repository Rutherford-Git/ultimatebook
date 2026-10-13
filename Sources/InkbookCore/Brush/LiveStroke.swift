import Foundation

/// The stroke being drawn, built incrementally so each new Pencil sample costs O(1).
///
/// Samples go through the same causal low-pass filter and distance decimation as
/// `BrushEngine.smooth` + `BrushEngine.simplify`, so `finished()` is exactly what a batch
/// smooth-then-simplify of all raw samples returns: the ink committed at pen-up is the ink that
/// was on screen while writing (no reshaping "snap" when the pencil lifts).
///
/// The newest raw sample is held back (the filter needs the next one to settle it) and drawn as
/// part of the temporary tail together with predicted touches.
public struct LiveStroke: Sendable {
    public let brush: Brush
    public let smoothing: Double
    public let minDistance: Double
    /// Settled points. Piece `i` is the segment `kept[i-1] → kept[i]` (piece 0 is a dot).
    public private(set) var kept: [InkPoint] = []
    /// Bounds of each piece, inflated by the brush radius.
    public private(set) var pieceBounds: [Rect] = []
    /// Newest raw sample, not yet settled.
    public private(set) var latest: InkPoint?
    private var filtered = Point(0, 0)

    public init(brush: Brush, smoothing: Double = 0.5, minDistance: Double = 0.6) {
        self.brush = brush
        self.smoothing = smoothing.clamped(0, 0.95)
        self.minDistance = minDistance
    }

    public var isEmpty: Bool { kept.isEmpty }

    /// Radius (half the diameter) of the pen at a sample.
    public func radius(_ p: InkPoint) -> Double { BrushEngine.diameter(for: brush, pressure: p.pressure) / 2 }

    /// Adds a raw sample. Returns the area of pieces settled by this call (nil when none), which
    /// is all the live layer needs to repaint besides the tail.
    @discardableResult
    public mutating func add(_ p: InkPoint) -> Rect? {
        guard let last = kept.last else {
            kept = [p]
            filtered = p.location
            pieceBounds = [piece(p, p)]
            return pieceBounds[0]
        }
        defer { latest = p }
        guard let pending = latest else { return nil }
        filtered = filtered * smoothing + pending.location * (1 - smoothing)
        guard filtered.distance(to: last.location) >= minDistance else { return nil }
        var settled = pending
        settled.location = filtered
        kept.append(settled)
        let r = piece(last, settled)
        pieceBounds.append(r)
        return r
    }

    /// The final point list: settled points plus the last raw sample.
    public func finished() -> [InkPoint] {
        guard let latest, latest != kept.last else { return kept }
        return kept + [latest]
    }

    /// Temporary points drawn after the settled part: last settled → latest raw → predictions.
    public func tail(predicted: [InkPoint]) -> [InkPoint] {
        guard let anchor = kept.last else { return [] }
        return [anchor] + (latest.map { [$0] } ?? []) + predicted
    }

    /// Bounds of a run of points inflated by the pen radius (for the tail's dirty rect).
    public func bounds(of points: [InkPoint]) -> Rect? {
        guard let r = Rect.bounding(points.map(\.location)) else { return nil }
        let pad = (points.map(radius).max() ?? 0) + 1.5
        return Rect(x: r.minX - pad, y: r.minY - pad, width: r.size.width + 2 * pad, height: r.size.height + 2 * pad)
    }

    private func piece(_ a: InkPoint, _ b: InkPoint) -> Rect { bounds(of: [a, b])! }
}
