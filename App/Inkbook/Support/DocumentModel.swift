import UIKit
import InkbookCore

enum Tool: String, CaseIterable, Identifiable {
    case pen, highlighter, pencil, airbrush, marker, eraser, lasso
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .pencil: "pencil"
        case .airbrush: "paintbrush.pointed"
        case .marker: "paintbrush"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }

    /// Raster tools paint on raster layers; vector tools write strokes to vector layers.
    var isRaster: Bool { [.pencil, .airbrush, .marker].contains(self) }
}

/// The open notebook: owns the model, its bitmaps, undo history and autosave.
/// Also the agent bridge's host — the agent can only reach the notebook through this type.
@MainActor
final class DocumentModel: ObservableObject {
    let store: NotebookStore
    lazy var renderer = PageRenderer(store: store)

    @Published private(set) var notebook: Notebook
    @Published var pageIndex = 0 { didSet { if oldValue != pageIndex { onPageChanged() } } }
    @Published var activeLayerID: UUID?
    @Published var tool: Tool = .pen
    @Published var brushes: [Tool: Brush] = [
        .pen: .pen,
        .highlighter: .highlighter,
        .pencil: Brush(kind: .pencil, color: RGBA(0.2, 0.2, 0.25, 0.9), size: 4, minSizeRatio: 0.3, spacing: 0.12, softness: 0.3),
        .airbrush: Brush(kind: .airbrush, color: RGBA(0.1, 0.4, 0.9, 0.08), size: 60, minSizeRatio: 0.6, spacing: 0.08, softness: 1),
        .marker: Brush(kind: .marker, color: RGBA(0.9, 0.2, 0.3, 1), size: 14, minSizeRatio: 0.7, spacing: 0.1, softness: 0),
        .eraser: Brush(kind: .eraser, color: .black, size: 24, minSizeRatio: 0.6, spacing: 0.1),
    ]
    /// Draw only with Apple Pencil; fingers pan/zoom (Goodnotes default).
    @Published var pencilOnly = true
    /// Pending agent change awaiting the user's decision (drives the approval sheet).
    @Published var pendingProposal: AgentProposal?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var bitmaps: [UUID: RasterLayerBitmap] = [:]
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var saveTask: Task<Void, Never>?

    private struct Snapshot {
        var notebook: Notebook
        var raster: (UUID, CGImage?)?
    }

    init(store: NotebookStore) throws {
        self.store = store
        notebook = try store.load()
        activeLayerID = notebook.pages.first?.layers.last(where: { $0.kind != .agent })?.id
    }

    var page: Page { notebook.pages[pageIndex] }
    var brush: Brush { brushes[tool] ?? .pen }
    var activeLayer: Layer? { page.layers.first { $0.id == activeLayerID } }

    // MARK: Editing

    func bitmap(for layer: Layer, on page: Page) -> RasterLayerBitmap? {
        if let b = bitmaps[layer.id] { return b }
        let b = RasterLayerBitmap(layerID: layer.id, pageSize: page.size, png: store.rasterData(for: layer.id))
        bitmaps[layer.id] = b
        return b
    }

    var rasterImages: [UUID: CGImage] {
        var out: [UUID: CGImage] = [:]
        for layer in page.layers where layer.kind == .raster {
            if let image = bitmap(for: layer, on: page)?.image { out[layer.id] = image }
        }
        return out
    }

    /// Records state before an edit so it can be undone.
    func beginEdit(rasterLayer: UUID? = nil) {
        undoStack.append(Snapshot(notebook: notebook, raster: rasterLayer.map { ($0, bitmaps[$0]?.snapshot()) }))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoState()
    }

    func mutate(_ change: (inout Notebook) -> Void) {
        change(&notebook)
        notebook.modified = Date()
        scheduleSave()
    }

    func addStroke(_ stroke: Stroke) {
        guard let layerID = activeLayerID, activeLayer?.kind == .vector, activeLayer?.isLocked == false else { return }
        beginEdit()
        mutate { nb in
            guard let li = nb.pages[self.pageIndex].layers.firstIndex(where: { $0.id == layerID }) else { return }
            nb.pages[self.pageIndex].layers[li].elements.append(.stroke(stroke))
        }
    }

    /// Vector eraser: removes whole strokes under the point, on the active vector or agent layer.
    func eraseStrokes(at point: InkbookCore.Point, radius: Double) {
        guard let layerID = activeLayerID,
              let li = page.layers.firstIndex(where: { $0.id == layerID }), page.layers[li].kind != .raster else { return }
        let hits = Set(BrushEngine.strokesHit(by: point, radius: radius, in: page.layers[li].elements))
        guard !hits.isEmpty else { return }
        mutate { $0.pages[self.pageIndex].layers[li].elements.removeAll { hits.contains($0.id) } }
    }

    func undo() { swapHistory(from: &undoStack, to: &redoStack) }
    func redo() { swapHistory(from: &redoStack, to: &undoStack) }

    private func swapHistory(from: inout [Snapshot], to: inout [Snapshot]) {
        guard let snap = from.popLast() else { return }
        to.append(Snapshot(notebook: notebook, raster: snap.raster.map { ($0.0, bitmaps[$0.0]?.snapshot()) }))
        notebook = snap.notebook
        if let (id, image) = snap.raster { bitmaps[id]?.restore(image) }
        pageIndex = min(pageIndex, notebook.pages.count - 1)
        updateUndoState()
        scheduleSave()
    }

    private func updateUndoState() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    /// Picks a tool and a matching target layer: raster tools need a raster layer (created on
    /// demand, Procreate-style); vector tools need a vector layer.
    func select(_ newTool: Tool) {
        tool = newTool
        guard newTool != .eraser, newTool != .lasso else { return }
        let wanted: LayerKind = newTool.isRaster ? .raster : .vector
        if activeLayer?.kind == wanted { return }
        if let match = page.layers.last(where: { $0.kind == wanted }) {
            activeLayerID = match.id
        } else {
            addLayer(kind: wanted)
        }
    }

    // MARK: Pages and layers

    private func onPageChanged() {
        guard notebook.pages.indices.contains(pageIndex) else { return }
        if !page.layers.contains(where: { $0.id == activeLayerID }) {
            activeLayerID = page.layers.last(where: { $0.kind != .agent })?.id ?? page.layers.first?.id
        }
    }

    func addPage(after index: Int? = nil) {
        beginEdit()
        let template = page
        mutate { $0.pages.insert(Page(size: template.size, paper: template.paper), at: (index ?? self.pageIndex) + 1) }
        pageIndex = (index ?? pageIndex) + 1
        activeLayerID = page.layers.first?.id
    }

    func addLayer(kind: LayerKind) {
        beginEdit()
        let layer = Layer(name: kind == .raster ? "Paint \(page.layers.count)" : "Ink \(page.layers.count)", kind: kind)
        mutate { nb in
            let agent = nb.pages[self.pageIndex].agentLayerIndex
            nb.pages[self.pageIndex].layers.insert(layer, at: agent ?? nb.pages[self.pageIndex].layers.count)
        }
        activeLayerID = layer.id
    }

    func updateLayer(_ id: UUID, _ change: @escaping (inout Layer) -> Void) {
        beginEdit()
        mutate { nb in
            guard let i = nb.pages[self.pageIndex].layers.firstIndex(where: { $0.id == id }) else { return }
            change(&nb.pages[self.pageIndex].layers[i])
        }
    }

    func deleteLayer(_ id: UUID) {
        guard page.layers.count > 1 else { return }
        beginEdit()
        mutate { $0.pages[self.pageIndex].layers.removeAll { $0.id == id } }
        if activeLayerID == id { activeLayerID = page.layers.last?.id }
    }

    func moveLayers(from: IndexSet, to: Int) {
        beginEdit()
        mutate { $0.pages[self.pageIndex].layers.move(fromOffsets: from, toOffset: to) }
    }

    // MARK: Persistence

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try store.save(notebook)
            for (id, bitmap) in bitmaps where bitmap.isDirty {
                if let png = bitmap.pngData() { try store.saveRaster(png, for: id); bitmap.markSaved() }
            }
        } catch {
            NSLog("Inkbook save failed: \(error.localizedDescription)")
        }
    }

    // MARK: Agent approval UI

    func resolvePending(_ decision: ApprovalDecision) {
        pendingProposal = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
    }
}

extension DocumentModel: AgentNotebookHost {
    func snapshot() async -> Notebook { notebook }

    func apply(_ proposal: AgentProposal) async throws {
        beginEdit()
        var copy = notebook
        try proposal.apply(to: &copy)
        mutate { $0 = copy }
    }

    func renderPage(_ index: Int, maxPixels: Int) async -> Data? {
        guard notebook.pages.indices.contains(index) else { return nil }
        let page = notebook.pages[index]
        var rasters: [UUID: CGImage] = [:]
        for layer in page.layers where layer.kind == .raster {
            if let image = bitmap(for: layer, on: page)?.image { rasters[layer.id] = image }
        }
        return renderer.png(of: page, rasters: rasters, maxPixels: maxPixels)
    }

    func requestApproval(_ proposal: AgentProposal) async -> ApprovalDecision {
        // One proposal at a time: the agent loop runs tools sequentially.
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pageIndex = proposal.pageIndex   // show the user where the change would go
            pendingProposal = proposal
        }
    }
}
