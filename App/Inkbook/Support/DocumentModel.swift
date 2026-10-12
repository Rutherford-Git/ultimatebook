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

/// The open notebook: owns the model, its bitmaps, undo history, selection, autosave and
/// background handwriting recognition. Also the agent bridge's host — the agent can only
/// reach the notebook through this type.
@MainActor
final class DocumentModel: ObservableObject {
    let store: NotebookStore
    lazy var renderer = PageRenderer(store: store)

    @Published private(set) var notebook: Notebook
    @Published var pageIndex = 0 { didSet { if oldValue != pageIndex { onPageChanged() } } }
    @Published var activeLayerID: UUID?
    @Published private(set) var tool: Tool = .pen
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
    /// Lasso selection on the active layer of the current page.
    @Published private(set) var selection: Set<UUID> = []
    /// Bumped on every content change; the canvas then redraws `takeDirtyRect()`.
    @Published private(set) var revision = 0
    /// Area of the current page awaiting redraw: `.null` = nothing, nil = whole page.
    private var pendingDirty: CGRect? = .null

    private var bitmaps: [UUID: RasterLayerBitmap] = [:]
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var saveTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var pagesNeedingRecognition: Set<UUID> = []

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
    private var activeLayerIndex: Int? { page.layers.firstIndex { $0.id == activeLayerID } }

    // MARK: Change tracking

    /// Marks part of the current page as needing redraw (nil = whole page).
    func invalidate(_ rect: CGRect?) {
        if let rect, let current = pendingDirty { pendingDirty = current.union(rect) } else { pendingDirty = nil }
        revision &+= 1
    }

    /// The area to redraw since the last call: `.null` = nothing, nil = whole page.
    func takeDirtyRect() -> CGRect? {
        defer { pendingDirty = .null }
        return pendingDirty
    }

    // MARK: Editing

    func bitmap(for layer: Layer, on page: Page) -> RasterLayerBitmap? {
        if let b = bitmaps[layer.id] { return b }
        let b = RasterLayerBitmap(layerID: layer.id, pageSize: page.size, png: store.rasterData(for: layer.id))
        bitmaps[layer.id] = b
        return b
    }

    func rasterImages(for page: Page) -> [UUID: CGImage] {
        var out: [UUID: CGImage] = [:]
        for layer in page.layers where layer.kind == .raster && layer.isVisible {
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

    /// Applies a change. `dirty` is the changed area of the current page (nil = everything);
    /// `inkChanged` queues the page for handwriting recognition.
    func mutate(dirty: Rect? = nil, inkChanged: Bool = false, _ change: (inout Notebook) -> Void) {
        change(&notebook)
        notebook.modified = Date()
        if inkChanged { pagesNeedingRecognition.insert(page.id) }
        invalidate(dirty?.cgRect)
        scheduleSave()
    }

    /// Ink goes to the active layer when it is an unlocked vector layer, otherwise to the topmost
    /// unlocked vector layer (created if there is none), so a stroke is never silently dropped.
    func addStroke(_ stroke: Stroke) {
        if activeLayer?.kind != .vector || activeLayer?.isLocked == true {
            if let target = page.layers.last(where: { $0.kind == .vector && !$0.isLocked }) { activeLayerID = target.id }
            else { addLayer(kind: .vector) }
        }
        guard let li = activeLayerIndex else { return }
        beginEdit()
        mutate(dirty: stroke.bounds, inkChanged: true) { $0.pages[self.pageIndex].layers[li].elements.append(.stroke(stroke)) }
    }

    /// Vector eraser: removes whole strokes/shapes under the point on the active vector or agent layer.
    func eraseStrokes(at point: InkbookCore.Point, radius: Double) {
        guard let li = activeLayerIndex, page.layers[li].kind != .raster, !page.layers[li].isLocked else { return }
        let elements = page.layers[li].elements
        var hits = Set(BrushEngine.strokesHit(by: point, radius: radius, in: elements))
        for case .shape(let s) in elements where s.path.flatMap(\.points).contains(where: { $0.distance(to: point) <= radius }) {
            hits.insert(s.id)
        }
        guard !hits.isEmpty else { return }
        let dirty = Lasso.bounds(of: hits, in: elements)
        mutate(dirty: dirty, inkChanged: true) { $0.pages[self.pageIndex].layers[li].elements.removeAll { hits.contains($0.id) } }
    }

    func undo() { swapHistory(from: &undoStack, to: &redoStack) }
    func redo() { swapHistory(from: &redoStack, to: &undoStack) }

    private func swapHistory(from: inout [Snapshot], to: inout [Snapshot]) {
        guard let snap = from.popLast() else { return }
        to.append(Snapshot(notebook: notebook, raster: snap.raster.map { ($0.0, bitmaps[$0.0]?.snapshot()) }))
        notebook = snap.notebook
        if let (id, image) = snap.raster { bitmaps[id]?.restore(image) }
        pageIndex = min(pageIndex, notebook.pages.count - 1)
        selection = []
        pagesNeedingRecognition.insert(page.id)
        updateUndoState()
        invalidate(nil)
        scheduleSave()
    }

    private func updateUndoState() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    /// Picks a tool and a matching target layer: raster tools need a raster layer (created on
    /// demand, Procreate-style); vector tools need a vector layer.
    func select(_ newTool: Tool) {
        if newTool != .lasso { clearSelection() }
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

    /// Commits a finished raster stroke: redraw its area and save the bitmap later.
    func rasterStrokeEnded(dirty: Rect?) {
        invalidate(dirty?.cgRect)
        scheduleSave()
    }

    // MARK: Lasso selection

    var selectionBounds: Rect? {
        guard let li = activeLayerIndex else { return nil }
        return Lasso.bounds(of: selection, in: page.layers[li].elements)
    }

    var selectedElements: [Element] {
        guard let li = activeLayerIndex else { return [] }
        return page.layers[li].elements.filter { selection.contains($0.id) }
    }

    /// Selects the elements of the active vector/agent layer enclosed by `polygon`.
    func lassoSelect(_ polygon: [InkbookCore.Point]) {
        guard let li = activeLayerIndex, page.layers[li].kind != .raster else { selection = []; return }
        selection = Set(Lasso.select(polygon, in: page.layers[li].elements))
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
    }

    func moveSelection(by offset: InkbookCore.Point) {
        guard let li = activeLayerIndex, !selection.isEmpty, !page.layers[li].isLocked,
              offset.x != 0 || offset.y != 0, let before = selectionBounds else { return }
        beginEdit()
        let ids = selection
        let after = Rect(x: before.minX + offset.x, y: before.minY + offset.y, width: before.size.width, height: before.size.height)
        mutate(dirty: Rect.bounding([before.origin, Point(before.maxX, before.maxY), after.origin, Point(after.maxX, after.maxY)]),
               inkChanged: true) { nb in
            nb.pages[self.pageIndex].layers[li].elements = nb.pages[self.pageIndex].layers[li].elements.map {
                ids.contains($0.id) ? $0.translated(by: offset) : $0
            }
        }
    }

    func deleteSelection() {
        guard let li = activeLayerIndex, !selection.isEmpty, !page.layers[li].isLocked else { return }
        beginEdit()
        let ids = selection, dirty = selectionBounds
        mutate(dirty: dirty, inkChanged: true) { $0.pages[self.pageIndex].layers[li].elements.removeAll { ids.contains($0.id) } }
        selection = []
    }

    /// Copies the selection 24 pt down-right and selects the copies.
    func duplicateSelection() {
        guard let li = activeLayerIndex, !selection.isEmpty, !page.layers[li].isLocked else { return }
        beginEdit()
        let copies = selectedElements.map { $0.withNewID().translated(by: Point(24, 24)) }
        let dirty = Lasso.bounds(of: Set(copies.map(\.id)), in: copies)
        mutate(dirty: dirty, inkChanged: true) { $0.pages[self.pageIndex].layers[li].elements.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
    }

    // MARK: Pages and layers

    private func onPageChanged() {
        guard notebook.pages.indices.contains(pageIndex) else { return }
        selection = []
        if !page.layers.contains(where: { $0.id == activeLayerID }) {
            activeLayerID = page.layers.last(where: { $0.kind != .agent })?.id ?? page.layers.first?.id
        }
        invalidate(nil)
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
        selection = []
    }

    func setActiveLayer(_ id: UUID) {
        activeLayerID = id
        selection = []
    }

    func updateLayer(_ id: UUID, recordUndo: Bool = true, _ change: @escaping (inout Layer) -> Void) {
        if recordUndo { beginEdit() }
        mutate { nb in
            guard let i = nb.pages[self.pageIndex].layers.firstIndex(where: { $0.id == id }) else { return }
            change(&nb.pages[self.pageIndex].layers[i])
        }
    }

    func deleteLayer(_ id: UUID) {
        guard page.layers.count > 1 else { return }
        beginEdit()
        mutate(inkChanged: true) { $0.pages[self.pageIndex].layers.removeAll { $0.id == id } }
        if activeLayerID == id { activeLayerID = page.layers.last?.id }
        selection = []
    }

    func moveLayers(from: IndexSet, to: Int) {
        beginEdit()
        mutate { $0.pages[self.pageIndex].layers.move(fromOffsets: from, toOffset: to) }
    }

    // MARK: Persistence and export

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
            self?.scheduleRecognition()
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

    /// Writes the notebook as a PDF to a temporary file for sharing.
    func exportPDF() throws -> URL {
        let data = renderer.pdfData(of: notebook) { self.rasterImages(for: $0) }
        let safe = notebook.title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "Notebook" : safe).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Handwriting recognition

    /// Re-recognizes edited pages a few seconds after the last edit, on-device (Vision).
    private func scheduleRecognition() {
        guard !pagesNeedingRecognition.isEmpty else { return }
        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            let ids = self.pagesNeedingRecognition
            self.pagesNeedingRecognition.removeAll()
            for id in ids {
                guard let page = self.notebook.pages.first(where: { $0.id == id }),
                      let image = self.renderer.inkImage(of: page, maxPixels: 2400).cgImage else { continue }
                let text: String
                do { text = try await HandwritingRecognizer.transcript(of: image, pageSize: page.size) } catch {
                    NSLog("Inkbook recognition failed: \(error.localizedDescription)")
                    continue
                }
                guard !Task.isCancelled, let index = self.notebook.pages.firstIndex(where: { $0.id == id }) else { continue }
                // Derived data: no undo entry, no redraw.
                self.notebook.pages[index].recognizedText = text.isEmpty ? nil : text
            }
            self.saveNow()
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
        return renderer.png(of: page, rasters: rasterImages(for: page), maxPixels: maxPixels)
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
