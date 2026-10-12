import Foundation

/// Freehand lasso selection over vector elements.
public enum Lasso {
    /// Even-odd point-in-polygon test (the polygon is implicitly closed).
    public static func contains(_ polygon: [Point], _ p: Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Ids of elements with at least `fraction` of their sample points inside the lasso,
    /// so a loop drawn around a word selects it even if a stroke tip pokes out.
    public static func select(_ polygon: [Point], in elements: [Element], fraction: Double = 0.6) -> [UUID] {
        guard polygon.count >= 3, let box = Rect.bounding(polygon) else { return [] }
        return elements.compactMap { element in
            guard let b = element.bounds, b.intersects(box) else { return nil }
            let samples = element.samplePoints
            guard !samples.isEmpty else { return nil }
            let inside = samples.filter { contains(polygon, $0) }.count
            return Double(inside) / Double(samples.count) >= fraction ? element.id : nil
        }
    }

    /// Union of the bounds of the given elements.
    public static func bounds(of ids: Set<UUID>, in elements: [Element]) -> Rect? {
        let rects = elements.filter { ids.contains($0.id) }.compactMap(\.bounds)
        return Rect.bounding(rects.flatMap { [$0.origin, Point($0.maxX, $0.maxY)] })
    }
}
