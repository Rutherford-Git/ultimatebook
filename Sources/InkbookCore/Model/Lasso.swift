import Foundation

/// Freehand lasso selection over vector elements.
public enum Lasso {
    /// Nonzero-winding point-in-polygon test (the polygon is implicitly closed). Unlike even-odd,
    /// areas where a hand-drawn lasso crosses itself still count as inside.
    public static func contains(_ polygon: [Point], _ p: Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var winding = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let side = (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
            if a.y <= p.y {
                if b.y > p.y, side > 0 { winding += 1 }
            } else if b.y <= p.y, side < 0 {
                winding -= 1
            }
        }
        return winding != 0
    }

    /// Ids of elements mostly inside the lasso: at least half of their evenly spread samples, or
    /// at least 20% when the element's center is inside (a highlighter running past the words it
    /// marks, a stroke tip poking out).
    public static func select(_ polygon: [Point], in elements: [Element]) -> [UUID] {
        guard polygon.count >= 3, let box = Rect.bounding(polygon) else { return [] }
        return elements.compactMap { element in
            guard let b = element.bounds, b.intersects(box) else { return nil }
            let samples = element.samplePoints
            guard !samples.isEmpty else { return nil }
            let fraction = Double(samples.filter { contains(polygon, $0) }.count) / Double(samples.count)
            let center = Point(b.minX + b.size.width / 2, b.minY + b.size.height / 2)
            return fraction >= 0.5 || (fraction >= 0.2 && contains(polygon, center)) ? element.id : nil
        }
    }

    /// Union of the bounds of the given elements.
    public static func bounds(of ids: Set<UUID>, in elements: [Element]) -> Rect? {
        let rects = elements.filter { ids.contains($0.id) }.compactMap(\.bounds)
        return Rect.bounding(rects.flatMap { [$0.origin, Point($0.maxX, $0.maxY)] })
    }
}
