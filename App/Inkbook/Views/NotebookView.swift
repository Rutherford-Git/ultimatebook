import SwiftUI
import InkbookCore

/// Writing screen. Only what is needed right now is on screen: a centered tool capsule, a preset
/// rail for the current tool, and a page pill. Everything else is one tap away (tap the active
/// tool for its options; the title menu holds notebook actions).
struct NotebookView: View {
    @ObservedObject var document: DocumentModel
    var close: () -> Void

    @StateObject private var presets = PenPresets()
    @StateObject private var chat = AgentChatModel()
    @AppStorage("notebook.lastBrush") private var lastBrush = Tool.pencil.rawValue
    @AppStorage("agent.enabled") private var agentEnabled = false
    @State private var optionsFor: Tool?
    @State private var showLayers = false
    @State private var showPages = false
    @State private var showAgent = false
    @State private var showAgentSettings = false
    @State private var exported: ExportedFile?
    @State private var exportError: String?
    @State private var renaming = false
    @State private var newTitle = ""

    private var brushTool: Tool { Tool(rawValue: lastBrush).flatMap { $0.isRaster ? $0 : nil } ?? .pencil }

    var body: some View {
        CanvasView(document: document)
            .ignoresSafeArea(edges: .bottom)
            .background(Color(Theme.backdrop).ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .overlay(alignment: .trailing) { presetRail }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if !document.selection.isEmpty { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
                    pagePill
                }
                .padding(.bottom, 18)
                .animation(.snappy, value: document.selection.isEmpty)
            }
            .tint(Theme.accent)
            .onAppear { applyPreset(document.tool) }
            .sheet(isPresented: $showLayers) { LayersPanel(document: document).presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showPages) { PagesSheet(document: document) }
            .sheet(isPresented: $showAgent) { AgentPanel(document: document, chat: chat).presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showAgentSettings) { AgentSettingsView() }
            .sheet(item: $exported) { ShareSheet(items: [$0.url]) }
            .alert("Rename notebook", isPresented: $renaming) {
                TextField("Title", text: $newTitle)
                Button("Rename") { document.rename(newTitle) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") {}
            } message: { Text(exportError ?? "") }
            // Approvals show here only while no other sheet is up; the agent panel shows its own.
            .approvalSheet(for: document, enabled: !showAgent && !showAgentSettings && !showLayers && !showPages)
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            HStack(spacing: 2) {
                BarButton("chevron.left", label: "Library", action: close)
                titleMenu
                Spacer()
                BarButton("arrow.uturn.backward", label: "Undo") { document.undo() }.disabled(!document.canUndo)
                BarButton("arrow.uturn.forward", label: "Redo") { document.redo() }.disabled(!document.canRedo)
                BarButton("square.3.layers.3d", label: "Layers") { showLayers = true }
                BarButton("sparkles", label: "Agent") {
                    if agentEnabled, KeychainStore.load() != nil { showAgent = true } else { showAgentSettings = true }
                }
            }
            toolCapsule
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var titleMenu: some View {
        Menu {
            Button { newTitle = document.notebook.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            Button { showPages = true } label: { Label("Pages", systemImage: "square.grid.2x2") }
            Button {
                document.saveNow()
                do { exported = ExportedFile(url: try document.exportPDF()) } catch { exportError = error.localizedDescription }
            } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
            Divider()
            Toggle(isOn: $document.pencilOnly) { Label("Draw with Apple Pencil only", systemImage: "applepencil") }
        } label: {
            HStack(spacing: 4) {
                Text(document.notebook.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: 220, alignment: .leading)
        }
    }

    private var toolCapsule: some View {
        HStack(spacing: 4) {
            toolButton(.pen, symbol: "pencil.tip", label: "Pen")
            toolButton(.highlighter, symbol: "highlighter", label: "Highlighter")
            toolButton(brushTool, symbol: brushTool.symbol, label: "Brush", isActive: document.tool.isRaster)
            toolButton(.eraser, symbol: "eraser", label: "Eraser")
            toolButton(.lasso, symbol: "lasso", label: "Lasso")
        }
        .padding(4)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private func toolButton(_ tool: Tool, symbol: String, label: String, isActive: Bool? = nil) -> some View {
        let active = isActive ?? (document.tool == tool)
        return Button {
            if active { optionsFor = tool } else { choose(tool) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 34)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? Theme.accent : .clear, in: Capsule())
                .overlay(alignment: .bottom) {
                    if active, let color = document.brushes[document.tool]?.color, document.tool != .eraser, document.tool != .lasso {
                        Capsule().fill(color.swatch).frame(width: 14, height: 3).offset(y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(active ? "Shows options" : "")
        .popover(isPresented: Binding(get: { optionsFor == tool || (optionsFor?.isRaster == true && tool.isRaster) },
                                      set: { if !$0 { optionsFor = nil } })) {
            ToolOptions(document: document, presets: presets, tool: document.tool) { choose($0) }
                .frame(width: 300)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func choose(_ tool: Tool) {
        if tool.isRaster { lastBrush = tool.rawValue }
        document.select(tool)
        applyPreset(tool)
    }

    private func applyPreset(_ tool: Tool) {
        if let brush = presets.current(for: tool) { document.brushes[tool] = brush }
    }

    // MARK: Preset rail

    @ViewBuilder private var presetRail: some View {
        let tool = document.tool
        let list = presets.brushes(for: tool)
        if !list.isEmpty {
            VStack(spacing: 10) {
                ForEach(list.indices, id: \.self) { i in
                    let selected = presets.selectedIndex(for: tool) == i
                    Button {
                        if selected { optionsFor = tool } else { presets.select(i, for: tool); applyPreset(tool) }
                    } label: {
                        PresetDot(brush: list[i], selected: selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preset \(i + 1)")
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.trailing, 12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    // MARK: Bottom

    private var pagePill: some View {
        HStack(spacing: 2) {
            BarButton("chevron.left", label: "Previous page") { document.pageIndex -= 1 }.disabled(document.pageIndex == 0)
            Button { showPages = true } label: {
                Text("\(document.pageIndex + 1) / \(document.notebook.pages.count)")
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .frame(minWidth: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pages")
            BarButton("chevron.right", label: "Next page") { document.pageIndex += 1 }
                .disabled(document.pageIndex >= document.notebook.pages.count - 1)
            Divider().frame(height: 18).padding(.horizontal, 2)
            BarButton("plus", label: "Add page") { document.addPage() }
        }
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    private var selectionBar: some View {
        HStack(spacing: 18) {
            Text("\(document.selection.count) selected").font(.footnote).foregroundStyle(.secondary)
            Button { document.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { document.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
            Button { document.clearSelection() } label: { Text("Done").bold() }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Plain icon button used in bars and pills.
struct BarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).frame(width: 38, height: 34)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

/// A preset swatch: ink color with a dot sized like the stroke.
struct PresetDot: View {
    let brush: Brush
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color(.systemBackground))
            Circle().fill(brush.color.swatch).padding(4)
            Circle().fill(.white.opacity(0.9))
                .frame(width: min(18, max(3, brush.size * (brush.kind == .highlighter || brush.kind == .airbrush ? 0.25 : 1.4))))
        }
        .frame(width: 34, height: 34)
        .overlay(Circle().stroke(selected ? Theme.accent : Color.black.opacity(0.08), lineWidth: selected ? 3 : 1).padding(-2))
        .scaleEffect(selected ? 1.08 : 1)
        .animation(.snappy, value: selected)
    }
}

/// Options for the active tool: brush type, color, size (popover from the tool capsule).
struct ToolOptions: View {
    @ObservedObject var document: DocumentModel
    @ObservedObject var presets: PenPresets
    let tool: Tool
    let choose: (Tool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if tool.isRaster {
                Picker("Brush", selection: Binding(get: { tool }, set: { choose($0) })) {
                    Text("Pencil").tag(Tool.pencil)
                    Text("Airbrush").tag(Tool.airbrush)
                    Text("Marker").tag(Tool.marker)
                }
                .pickerStyle(.segmented)
            }
            switch tool {
            case .lasso:
                Label("Circle items to select them. Drag inside the box to move; use the bar below to duplicate or delete.",
                      systemImage: "lasso").font(.callout).foregroundStyle(.secondary)
            case .eraser:
                sizeRow(range: 6...80)
                Text("Removes whole strokes on ink layers and paints out on paint layers.")
                    .font(.footnote).foregroundStyle(.secondary)
            default:
                colorRow
                sizeRow(range: tool == .highlighter ? 6...40 : tool == .airbrush ? 10...160 : 0.5...30)
                preview
            }
        }
        .padding(18)
    }

    private var brush: Brush? { document.brushes[tool] }

    private func update(_ change: @escaping (inout Brush) -> Void) {
        if presets.current(for: tool) != nil {
            presets.updateCurrent(for: tool, change)
            document.brushes[tool] = presets.current(for: tool)
        } else if var b = document.brushes[tool] {
            change(&b)
            document.brushes[tool] = b
        }
    }

    private var colorRow: some View {
        let palette = tool == .highlighter ? Theme.highlighterColors : Theme.inkColors
        return HStack(spacing: 10) {
            ForEach(palette.indices, id: \.self) { i in
                let c = palette[i]
                Button { update { $0.color = c } } label: {
                    Circle().fill(c.swatch).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: brush?.color == c ? 3 : 0).padding(-3))
                }
                .buttonStyle(.plain)
            }
            ColorPicker("Custom color", selection: Binding(get: { brush?.color.swiftUI ?? .black },
                                                           set: { c in update { $0.color = c.rgba } }),
                        supportsOpacity: tool != .pen)
                .labelsHidden()
        }
    }

    private func sizeRow(range: ClosedRange<Double>) -> some View {
        HStack {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { brush?.size ?? range.lowerBound }, set: { v in update { $0.size = v } }), in: range)
            Image(systemName: "circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
            Text(String(format: "%.1f", brush?.size ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var preview: some View {
        Canvas { ctx, size in
            guard let b = brush else { return }
            var path = Path()
            path.move(to: CGPoint(x: 12, y: size.height * 0.65))
            path.addCurve(to: CGPoint(x: size.width - 12, y: size.height * 0.35),
                          control1: CGPoint(x: size.width * 0.35, y: -size.height * 0.1),
                          control2: CGPoint(x: size.width * 0.6, y: size.height * 1.1))
            ctx.stroke(path, with: .color(b.color.swiftUI), style: StrokeStyle(lineWidth: min(b.size, 30), lineCap: .round))
        }
        .frame(height: 44)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Grid of page thumbnails: jump to a page or add one.
struct PagesSheet: View {
    @ObservedObject var document: DocumentModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 20)], spacing: 22) {
                    ForEach(Array(document.notebook.pages.enumerated()), id: \.element.id) { index, page in
                        Button { document.pageIndex = index; dismiss() } label: {
                            VStack(spacing: 6) {
                                PageThumbnail(document: document, page: page)
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(Theme.accent, lineWidth: index == document.pageIndex ? 3 : 0))
                                Text("\(index + 1)").font(.caption.monospacedDigit())
                                    .foregroundStyle(index == document.pageIndex ? Theme.accent : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
            .background(Color(Theme.backdrop))
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { document.addPage(after: document.notebook.pages.count - 1); dismiss() } label: {
                        Label("Add page", systemImage: "plus")
                    }
                }
            }
        }
    }
}

struct PageThumbnail: View {
    @ObservedObject var document: DocumentModel
    let page: Page
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(Color.white).aspectRatio(page.size.width / page.size.height, contentMode: .fit) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .task(id: page) {
            image = document.renderer.image(of: page, rasters: document.rasterImages(for: page), maxPixels: 320)
        }
    }
}
