import Foundation
import InkbookCore

/// Four quick presets per drawing tool (shown as the floating rail on the right edge),
/// remembered across launches. The selected preset is the brush the canvas draws with.
@MainActor
final class PenPresets: ObservableObject {
    static let tools: [Tool] = [.pen, .highlighter, .pencil, .airbrush, .marker]

    @Published private(set) var presets: [Tool: [Brush]]
    @Published private(set) var selected: [Tool: Int]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.data(forKey: "presets.v1")).flatMap { try? JSONDecoder().decode([String: [Brush]].self, from: $0) }
        var p: [Tool: [Brush]] = [:]
        for tool in Self.tools {
            p[tool] = saved?[tool.rawValue].flatMap { $0.count == 4 ? $0 : nil } ?? Self.factory(tool)
        }
        presets = p
        let sel = defaults.dictionary(forKey: "presets.selected.v1") as? [String: Int] ?? [:]
        selected = Dictionary(uniqueKeysWithValues: Self.tools.map { ($0, min(max(sel[$0.rawValue] ?? 0, 0), 3)) })
    }

    func brushes(for tool: Tool) -> [Brush] { presets[tool] ?? [] }
    func selectedIndex(for tool: Tool) -> Int { selected[tool] ?? 0 }
    func current(for tool: Tool) -> Brush? { brushes(for: tool)[safe: selectedIndex(for: tool)] }

    func select(_ index: Int, for tool: Tool) {
        selected[tool] = index
        persist()
    }

    /// Edits the selected preset (from the tool options popover).
    func updateCurrent(for tool: Tool, _ change: (inout Brush) -> Void) {
        guard var list = presets[tool], list.indices.contains(selectedIndex(for: tool)) else { return }
        change(&list[selectedIndex(for: tool)])
        presets[tool] = list
        persist()
    }

    private func persist() {
        let encoded = Dictionary(uniqueKeysWithValues: presets.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { defaults.set(data, forKey: "presets.v1") }
        defaults.set(Dictionary(uniqueKeysWithValues: selected.map { ($0.key.rawValue, $0.value) }), forKey: "presets.selected.v1")
    }

    static func factory(_ tool: Tool) -> [Brush] {
        let ink = Theme.inkColors, hl = Theme.highlighterColors
        switch tool {
        case .pen:
            return [Brush(kind: .pen, color: ink[0], size: 2.4), Brush(kind: .pen, color: ink[1], size: 2.4),
                    Brush(kind: .pen, color: ink[2], size: 2.4), Brush(kind: .pen, color: ink[0], size: 5)]
        case .highlighter:
            return hl.prefix(4).map { Brush(kind: .highlighter, color: $0, size: 18, minSizeRatio: 1) }
        case .pencil:
            return [RGBA(0.2, 0.2, 0.25, 0.9), RGBA(0.45, 0.45, 0.5, 0.8), ink[1], ink[2]].map {
                Brush(kind: .pencil, color: $0, size: 4, minSizeRatio: 0.3, spacing: 0.12, softness: 0.3)
            }
        case .airbrush:
            return [RGBA(0.1, 0.4, 0.9, 0.08), RGBA(0.9, 0.3, 0.4, 0.08), RGBA(0.2, 0.7, 0.4, 0.08), RGBA(0.1, 0.1, 0.1, 0.08)].map {
                Brush(kind: .airbrush, color: $0, size: 60, minSizeRatio: 0.6, spacing: 0.08, softness: 1)
            }
        case .marker:
            return [RGBA(0.9, 0.2, 0.3), RGBA(0.2, 0.45, 0.9), RGBA(0.15, 0.6, 0.35), RGBA(0.1, 0.1, 0.12)].map {
                Brush(kind: .marker, color: $0, size: 14, minSizeRatio: 0.7, spacing: 0.1, softness: 0)
            }
        case .eraser, .lasso:
            return []
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
