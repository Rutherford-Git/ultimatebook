import Foundation

/// What a lasso selects on one page, and what it passed over. The app uses the same function for
/// selection, the notice shown to the user and the diagnostics log, so they cannot disagree.
public struct LassoReport: Equatable, Sendable {
    public struct LayerCount: Equatable, Sendable {
        public var name: String
        public var hit: Int
        public var total: Int
    }

    /// Elements selected (from selectable layers only).
    public var selected: [UUID]
    /// Per selectable layer, in stacking order.
    public var layers: [LayerCount]
    /// Items inside the lasso on hidden or locked layers, which are never selected.
    public var skippedHidden: [LayerCount]
    public var skippedLocked: [LayerCount]
    /// Visible paint layers the lasso crosses. Paint pixels cannot be selected yet.
    public var paintUnder: [String]

    /// Human-readable line for the log.
    public var summary: String {
        let total = layers.reduce(0) { $0 + $1.total }
        var parts = ["selected \(selected.count) of \(total) items on selectable layers"]
        let per = layers.filter { $0.hit > 0 }.map { "\($0.name) \($0.hit)/\($0.total)" }
        if !per.isEmpty { parts.append("per layer: " + per.joined(separator: ", ")) }
        if !skippedHidden.isEmpty { parts.append("skipped hidden: " + skippedHidden.map { "\($0.name) \($0.hit)" }.joined(separator: ", ")) }
        if !skippedLocked.isEmpty { parts.append("skipped locked: " + skippedLocked.map { "\($0.name) \($0.hit)" }.joined(separator: ", ")) }
        if !paintUnder.isEmpty { parts.append("paint not selectable: " + paintUnder.joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }

    /// Short message for the user when something inside the lasso was not selected, else nil.
    public var notice: String? {
        var lines: [String] = []
        if !paintUnder.isEmpty {
            lines.append("Paint can't be lassoed yet (\(paintUnder.joined(separator: ", ")))")
        }
        for skipped in skippedHidden where skipped.hit > 0 {
            lines.append("\(skipped.hit) item\(skipped.hit == 1 ? "" : "s") on hidden \u{201C}\(skipped.name)\u{201D} not selected")
        }
        for skipped in skippedLocked where skipped.hit > 0 {
            lines.append("\(skipped.hit) item\(skipped.hit == 1 ? "" : "s") on locked \u{201C}\(skipped.name)\u{201D} not selected")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

public extension Page {
    /// - Parameter paintUnder: names of visible paint layers whose pixels the lasso crosses (the app
    ///   checks the bitmap bounds, which Core does not own).
    func lassoReport(_ polygon: [Point], paintUnder: [String] = []) -> LassoReport {
        var selected: [UUID] = []
        var layers: [LassoReport.LayerCount] = []
        var hidden: [LassoReport.LayerCount] = []
        var locked: [LassoReport.LayerCount] = []
        for layer in self.layers where layer.kind != .raster {
            let hits = Lasso.select(polygon, in: layer.elements)
            let count = LassoReport.LayerCount(name: layer.name, hit: hits.count, total: layer.elements.count)
            if !layer.isVisible {
                if hits.count > 0 { hidden.append(count) }
            } else if layer.isLocked {
                if hits.count > 0 { locked.append(count) }
            } else {
                selected += hits
                layers.append(count)
            }
        }
        return LassoReport(selected: selected, layers: layers, skippedHidden: hidden, skippedLocked: locked,
                           paintUnder: paintUnder)
    }
}
