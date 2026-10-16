import SwiftUI
import InkbookCore

/// Procreate-style layer list for the current page (top of list = top of stack).
struct LayersPanel: View {
    @ObservedObject var document: DocumentModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(document.page.layers.reversed()) { layer in
                    row(layer)
                        .listRowBackground(layer.id == document.activeLayerID ? Theme.accent.opacity(0.12) : Color.clear)
                }
                .onMove { from, to in
                    // List shows layers reversed; convert offsets back to model order.
                    let count = document.page.layers.count
                    let modelFrom = IndexSet(from.map { count - 1 - $0 })
                    document.moveLayers(from: modelFrom, to: count - to)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Layers")
            .toolbar {
                Menu {
                    Button("Ink layer (vector)") { document.addLayer(kind: .vector) }
                    Button("Paint layer (raster)") { document.addLayer(kind: .raster) }
                } label: { Image(systemName: "plus") }
            }
        }
    }

    private func row(_ layer: Layer) -> some View {
        let active = layer.id == document.activeLayerID
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { document.updateLayer(layer.id) { $0.isVisible.toggle() } } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                }.buttonStyle(.borderless)
                Image(systemName: icon(layer.kind)).foregroundStyle(active ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    // Inactive layers are dimmed; the active one is marked so the target is never in doubt.
                    Text(layer.name).fontWeight(active ? .bold : .regular)
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                    if active { Text("New strokes go here").font(.caption2).foregroundStyle(Theme.accent) }
                }
                Spacer()
                Button { document.updateLayer(layer.id) { $0.isLocked.toggle() } } label: {
                    Image(systemName: layer.isLocked ? "lock" : "lock.open")
                }.buttonStyle(.borderless)
                if document.page.layers.count > 1 {
                    Button(role: .destructive) { document.deleteLayer(layer.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Text("Opacity").font(.caption)
                Slider(value: Binding(get: { layer.opacity },
                                      set: { v in document.updateLayer(layer.id, recordUndo: false) { $0.opacity = v } }),
                       in: 0...1)
                Picker("", selection: Binding(get: { layer.blendMode },
                                              set: { m in document.updateLayer(layer.id) { $0.blendMode = m } })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                }.labelsHidden().frame(width: 120)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { document.setActiveLayer(layer.id) }
    }

    private func icon(_ kind: LayerKind) -> String {
        switch kind {
        case .vector: "scribble"
        case .raster: "paintpalette"
        case .agent: "sparkles"
        }
    }
}
