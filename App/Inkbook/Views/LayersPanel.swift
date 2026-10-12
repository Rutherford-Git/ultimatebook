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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { document.updateLayer(layer.id) { $0.isVisible.toggle() } } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                }.buttonStyle(.borderless)
                Image(systemName: icon(layer.kind)).foregroundStyle(.secondary)
                Text(layer.name).fontWeight(layer.id == document.activeLayerID ? .bold : .regular)
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
