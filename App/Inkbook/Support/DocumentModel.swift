import PDFKit
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
    /// Why part of a lasso was not selected (paint, hidden or locked layers), shown briefly.
    @Published private(set) var lassoNotice: String?
    private var lassoNoticeTask: Task<Void, Never>?
    /// What caused the last full-page redraw, for the diagnostics log.
    private(set) var lastFullRedrawReason = "unknown"
    /// Bumped on every content change; the canvas then redraws `takeDirtyRect()`.
    @Published private(set) var revision = 0

    enum SaveState: Equatable {
        case saved(Date)
        /// Edits waiting for the next save.
        case pending
        /// The last save failed; another attempt is scheduled.
        case failed(String)
    }
    /// Shown in the title menu, and as a notice while a save is failing.
    @Published private(set) var saveState: SaveState = .saved(Date())
    private var saveGeneration = 0
    private var retryDelay: UInt64 = 2
    private var retryTask: Task<Void, Never>?
    /// Area of the current page awaiting redraw: `.null` = nothing, nil = whole page.
    private var pendingDirty: CGRect? = .null

    private var bitmaps: [UUID: RasterLayerBitmap] = [:]
    /// Undo/redo history, persisted in the bundle so it survives closing the app.
    private let history: HistoryStore
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    /// History entries (and raster snapshots) not yet written to disk.
    private var unsavedEntries: Set<UUID> = []
    private var pendingRasters: [UUID: CGImage] = [:]
    private var encodingRasters: Set<UUID> = []
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var saveTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var pagesNeedingRecognition: Set<UUID> = []
    /// Last time the user touched the canvas; background work waits for a pause in writing.
    private var lastInkActivity: CFTimeInterval = 0
    /// Disk writes run in order on one serial queue, off the main thread: encoding a full page of
    /// ink on the main thread caused a visible hitch when writing resumed after a short pause.
    private static let saveQueue = DispatchQueue(label: "app.inkbook.save", qos: .utility)

    init(store: NotebookStore) throws {
        self.store = store
        notebook = try store.load()
        history = HistoryStore(bundle: store.url)
        (undoStack, redoStack) = history.load()
        activeLayerID = notebook.pages.first.flatMap(Self.defaultLayer)?.id
        updateUndoState()
        saveState = .saved(notebook.modified)
        AppDiagnostics.log.info("notebook", "Opened \"\(notebook.title)\" (\(notebook.pages.count) pages, \(undoStack.count) undo steps)")
        extractMissingPDFText()
    }

    /// PDF pages imported before page text was kept get it now, in the background, so search
    /// and the agent can read them. Scans get an empty string so they are not retried.
    private func extractMissingPDFText() {
        let missing = notebook.pages.compactMap { page -> (UUID, String, Int)? in
            guard page.backgroundText == nil, case .asset(let name, let index?) = page.paper else { return nil }
            return (page.id, name, index)
        }
        guard !missing.isEmpty else { return }
        let store = store
        Task.detached(priority: .utility) { [weak self] in
            var documents: [String: PDFDocument] = [:]
            var texts: [UUID: String] = [:]
            for (id, name, index) in missing {
                if documents[name] == nil, let data = try? store.assetData(named: name) { documents[name] = PDFDocument(data: data) }
                texts[id] = documents[name]?.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            await self?.setBackgroundText(texts)
        }
    }

    private func setBackgroundText(_ texts: [UUID: String]) {
        for i in notebook.pages.indices {
            if let text = texts[notebook.pages[i].id] { notebook.pages[i].backgroundText = text }
        }
        scheduleSave()   // derived data: no undo step, no redraw
    }

    /// Pages matching `query` in typed text, handwriting and PDF text.
    func search(_ query: String) -> [SearchIndex.Hit] { SearchIndex(notebook).hits(for: query) }

    func noteInkActivity() { lastInkActivity = CACurrentMediaTime() }

    /// Stops pending background saves and recognition (used for scratch notebooks).
    func cancelBackgroundWork() {
        saveTask?.cancel()
        retryTask?.cancel()
        recognitionTask?.cancel()
    }

    var page: Page { notebook.pages[pageIndex] }
    var brush: Brush { brushes[tool] ?? .pen }
    var activeLayer: Layer? { page.layers.first { $0.id == activeLayerID } }
    private var activeLayerIndex: Int? { page.layers.firstIndex { $0.id == activeLayerID } }

    // MARK: Change tracking

    /// Marks part of the current page as needing redraw (nil = whole page).
    func invalidate(_ rect: CGRect?, reason: String = "edit") {
        if let rect, let current = pendingDirty { pendingDirty = current.union(rect) } else {
            pendingDirty = nil
            lastFullRedrawReason = reason
        }
        revision &+= 1
    }

    /// Redraws only what a change touched. Whole-page changes are logged with their cause.
    func invalidate(_ change: PageChange, reason: String) {
        switch change {
        case .none: revision &+= 1
        case .area(let r): invalidate(r.cgRect)
        case .wholePage: invalidate(nil, reason: reason)
        }
    }

    /// Records a full-page redraw requested outside the model (zoom, for example).
    func noteFullRedraw(_ reason: String) { lastFullRedrawReason = reason }

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

    /// Records a page's state before an edit so it can be undone (default: the current page).
    /// With `rasterLayer`, that layer's bitmap is captured too.
    func beginEdit(rasterLayer: UUID? = nil, pageID: UUID? = nil) {
        guard let target = notebook.pages.first(where: { $0.id == (pageID ?? page.id) }) else { return }
        record(HistoryEntry(change: .page(target), rasterLayer: rasterLayer))
    }

    private func record(_ entry: HistoryEntry) {
        if let layerID = entry.rasterLayer, let image = rasterSnapshot(layerID) { pendingRasters[entry.id] = image }
        undoStack.append(entry)
        unsavedEntries.insert(entry.id)
        redoStack.removeAll()
        updateUndoState()
    }

    /// Current bitmap of a raster layer, loading it first so a never-painted-this-session layer
    /// is captured with its saved content (not as blank, which undo would then restore).
    private func rasterSnapshot(_ layerID: UUID) -> CGImage? {
        guard let page = notebook.pages.first(where: { $0.layers.contains { $0.id == layerID } }),
              let layer = page.layers.first(where: { $0.id == layerID }) else { return nil }
        return bitmap(for: layer, on: page)?.snapshot()
    }

    /// Applies a change. `dirty` is the changed area of the current page (nil = everything);
    /// `inkChanged` queues the page for handwriting recognition.
    func mutate(dirty: Rect? = nil, inkChanged: Bool = false, _ change: (inout Notebook) -> Void) {
        change(&notebook)
        notebook.modified = Date()
        if inkChanged { pagesNeedingRecognition.insert(page.id) }
        invalidate(dirty?.cgRect)
        if case .saved = saveState { saveState = .pending }
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

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        let before = notebook.pages, oldIndex = pageIndex
        if let inverse = applyHistory(entry) { redoStack.append(inverse) }
        historyChanged(before: before, oldIndex: oldIndex, hadRaster: entry.rasterLayer != nil)
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        let before = notebook.pages, oldIndex = pageIndex
        if let inverse = applyHistory(entry) { undoStack.append(inverse) }
        historyChanged(before: before, oldIndex: oldIndex, hadRaster: entry.rasterLayer != nil)
    }

    /// Applies a history entry and returns its inverse (nil if it no longer applies).
    private func applyHistory(_ entry: HistoryEntry) -> HistoryEntry? {
        let currentRaster = entry.rasterLayer.flatMap(rasterSnapshot)
        guard let inverseChange = entry.change.apply(to: &notebook) else { return nil }
        notebook.modified = Date()
        let inverse = HistoryEntry(change: inverseChange, rasterLayer: entry.rasterLayer)
        if let layerID = entry.rasterLayer {
            if let image = savedRaster(for: entry), let page = notebook.pages.first(where: { $0.layers.contains { $0.id == layerID } }),
               let layer = page.layers.first(where: { $0.id == layerID }) {
                bitmap(for: layer, on: page)?.restore(image)
            }
            if let currentRaster { pendingRasters[inverse.id] = currentRaster }
        }
        pendingRasters[entry.id] = nil
        unsavedEntries.remove(entry.id)
        unsavedEntries.insert(inverse.id)
        // Show where the change happened.
        if let index = notebook.pages.firstIndex(where: { $0.id == entry.change.pageID }) { pageIndex = index }
        pageIndex = min(pageIndex, notebook.pages.count - 1)
        pagesNeedingRecognition.insert(page.id)
        return inverse
    }

    private func savedRaster(for entry: HistoryEntry) -> CGImage? {
        if let image = pendingRasters[entry.id] { return image }
        return history.rasterData(for: entry.id).flatMap { UIImage(data: $0)?.cgImage }
    }

    /// Redraws only the area an undo or redo changed on the same page. Page switches, paint
    /// layers and structural changes redraw the whole page.
    private func historyChanged(before: [Page], oldIndex: Int, hadRaster: Bool) {
        selection = []
        ensureValidActiveLayer()
        updateUndoState()
        var change = PageChange.wholePage
        if !hadRaster, pageIndex == oldIndex, before.indices.contains(pageIndex), notebook.pages.indices.contains(pageIndex) {
            change = Page.change(from: before[pageIndex], to: notebook.pages[pageIndex])
        }
        invalidate(change, reason: "undo or redo")
        scheduleSave()
    }

    /// Keeps `activeLayerID` pointing at a layer of the current page (undo can remove layers).
    private func ensureValidActiveLayer() {
        if !page.layers.contains(where: { $0.id == activeLayerID }) {
            activeLayerID = Self.defaultLayer(of: page)?.id
        }
    }

    /// Preferred drawing layer: topmost unlocked vector layer, else any non-agent layer.
    static func defaultLayer(of page: Page) -> Layer? {
        page.layers.last { $0.kind == .vector && !$0.isLocked } ?? page.layers.last { $0.kind != .agent } ?? page.layers.first
    }

    /// Assigns only on change: every assignment to a published property re-renders the screen.
    private func updateUndoState() {
        if canUndo == undoStack.isEmpty { canUndo = !undoStack.isEmpty }
        if canRedo == redoStack.isEmpty { canRedo = !redoStack.isEmpty }
    }

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

    /// Lasso works across every visible, unlocked vector and agent layer of the page (not just the
    /// active layer), so it behaves the same whatever layer was last used.
    private var selectableLayerIndices: [Int] {
        page.layers.indices.filter { page.layers[$0].kind != .raster && page.layers[$0].isVisible && !page.layers[$0].isLocked }
    }

    var selectionBounds: Rect? {
        guard !selection.isEmpty else { return nil }
        return Lasso.bounds(of: selection, in: selectableLayerIndices.flatMap { page.layers[$0].elements })
    }

    var selectedElements: [Element] {
        selectableLayerIndices.flatMap { page.layers[$0].elements.filter { selection.contains($0.id) } }
    }

    /// Selects what the lasso encloses. Anything it passed over is reported, and the same numbers go
    /// to the diagnostics log, so a missed selection is visible instead of silent.
    func lassoSelect(_ polygon: [InkbookCore.Point]) {
        let box = Rect.bounding(polygon)
        let paintUnder = page.layers.filter { $0.kind == .raster && $0.isVisible }.filter { layer in
            guard let box, let painted = bitmap(for: layer, on: page)?.paintedBounds else { return false }
            return painted.intersects(box)
        }.map(\.name)
        let report = page.lassoReport(polygon, paintUnder: paintUnder)
        selection = Set(report.selected)
        showLassoNotice(report.notice)
        AppDiagnostics.log.info("lasso", report.summary)
    }

    private func showLassoNotice(_ text: String?) {
        lassoNoticeTask?.cancel()
        lassoNotice = text
        guard text != nil else { return }
        lassoNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lassoNotice = nil
        }
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
    }

    /// Applies `transform` to the selected elements of every selectable layer.
    private func editSelection(dirty: Rect?, _ transform: @escaping (_ selected: [Element]) -> (keep: Bool, add: [Element])) {
        let ids = selection, layers = selectableLayerIndices, pageIndex = pageIndex
        mutate(dirty: dirty, inkChanged: true) { nb in
            for li in layers {
                let elements = nb.pages[pageIndex].layers[li].elements
                let selected = elements.filter { ids.contains($0.id) }
                guard !selected.isEmpty else { continue }
                let (keep, add) = transform(selected)
                if !keep { nb.pages[pageIndex].layers[li].elements.removeAll { ids.contains($0.id) } }
                nb.pages[pageIndex].layers[li].elements.append(contentsOf: add)
            }
        }
    }

    func moveSelection(by offset: InkbookCore.Point) {
        guard !selection.isEmpty, offset.x != 0 || offset.y != 0, let before = selectionBounds else { return }
        beginEdit()
        let after = Rect(x: before.minX + offset.x, y: before.minY + offset.y, width: before.size.width, height: before.size.height)
        let dirty = Rect.bounding([before.origin, Point(before.maxX, before.maxY), after.origin, Point(after.maxX, after.maxY)])
        // Replace in place (remove + re-add) so stacking order within the layer is kept for the group.
        editSelection(dirty: dirty) { selected in (false, selected.map { $0.translated(by: offset) }) }
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        beginEdit()
        editSelection(dirty: selectionBounds) { _ in (false, []) }
        selection = []
    }

    /// Copies the selection 24 pt down-right (each copy on its source layer) and selects the copies.
    func duplicateSelection() {
        guard !selection.isEmpty, let before = selectionBounds else { return }
        beginEdit()
        var newIDs: Set<UUID> = []
        let offset = Point(24, 24)
        let dirty = Rect(x: before.minX + 24, y: before.minY + 24, width: before.size.width, height: before.size.height)
        editSelection(dirty: dirty) { selected in
            let copies = selected.map { $0.withNewID().translated(by: offset) }
            newIDs.formUnion(copies.map(\.id))
            return (true, copies)
        }
        selection = newIDs
    }

    // MARK: Pages and layers

    private func onPageChanged() {
        guard notebook.pages.indices.contains(pageIndex) else { return }
        selection = []
        ensureValidActiveLayer()
        invalidate(nil, reason: "page change")
    }

    func addPage(after index: Int? = nil) {
        let newPage = Page(size: page.size, paper: page.paper)
        record(HistoryEntry(change: .removePage(newPage.id)))
        mutate { $0.pages.insert(newPage, at: (index ?? self.pageIndex) + 1) }
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

    /// Snapshots the notebook and changed bitmaps on the main thread (cheap: value copies and
    /// copy-on-write images), then encodes and writes them on the save queue.
    /// `wait` blocks until everything queued so far is on disk (closing, exporting).
    func saveNow(wait: Bool = false) {
        let notebook = notebook, store = store, log = AppDiagnostics.log
        var rasters: [(UUID, CGImage)] = []
        for (id, bitmap) in bitmaps where bitmap.isDirty {
            if let image = bitmap.image { rasters.append((id, image)); bitmap.markSaved() }
        }
        saveGeneration += 1
        let generation = saveGeneration
        retryTask?.cancel()
        Self.saveQueue.async { [weak self] in
            var failure: String?
            var failedRasters: [UUID] = []
            do { try store.save(notebook) } catch {
                failure = error.localizedDescription
                log.error("save", "Saving \"\(notebook.title)\" failed: \(error.localizedDescription)")
            }
            for (id, image) in rasters {
                do {
                    guard let png = UIImage(cgImage: image).pngData() else { throw CocoaError(.fileWriteUnknown) }
                    try store.saveRaster(png, for: id)
                } catch {
                    failure = failure ?? error.localizedDescription
                    failedRasters.append(id)
                    log.error("save", "Saving a paint layer failed: \(error.localizedDescription)")
                }
            }
            Task { @MainActor in self?.saveFinished(generation, failure: failure, failedRasters: failedRasters) }
        }
        saveHistory()
        if wait { Self.saveQueue.sync {} }
    }

    /// Updates the save state; a failed save is retried with growing delays (2 s up to 30 s).
    private func saveFinished(_ generation: Int, failure: String?, failedRasters: [UUID]) {
        for id in failedRasters { bitmaps[id]?.markUnsaved() }
        if let failure {
            saveState = .failed(failure)
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 30)
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                AppDiagnostics.log.info("save", "Retrying save of \"\(self.notebook.title)\"")
                self.saveNow()
            }
        } else if generation == saveGeneration {
            if case .failed = saveState { AppDiagnostics.log.info("save", "Save recovered") }
            saveState = .saved(Date())
            retryDelay = 2
        }
    }

    /// Writes new history entries and the index on the save queue; raster snapshots are
    /// PNG-encoded off the main thread and released from memory once written.
    private func saveHistory() {
        let live = Set(undoStack.map(\.id) + redoStack.map(\.id))
        let entries = (undoStack + redoStack).filter { unsavedEntries.contains($0.id) }
        unsavedEntries.removeAll()
        let undoIDs = undoStack.map(\.id), redoIDs = redoStack.map(\.id)
        let history = history, log = AppDiagnostics.log
        Self.saveQueue.async { [weak self] in
            for entry in entries {
                do { try history.write(entry) } catch { log.error("history", "Writing an undo step failed: \(error.localizedDescription)") }
            }
            do {
                let dropped = Set(try history.saveIndex(undo: undoIDs, redo: redoIDs))
                if !dropped.isEmpty { Task { @MainActor in self?.dropHistory(dropped) } }
            } catch {
                log.error("history", "Writing the undo index failed: \(error.localizedDescription)")
            }
        }
        pendingRasters = pendingRasters.filter { live.contains($0.key) }
        for (id, image) in pendingRasters where !encodingRasters.contains(id) {
            encodingRasters.insert(id)
            Task.detached(priority: .utility) { [weak self] in
                if let png = UIImage(cgImage: image).pngData() { try? history.writeRaster(png, for: id) }
                await self?.rasterWritten(id)
            }
        }
    }

    /// Oldest steps trimmed by the history size limit.
    private func dropHistory(_ ids: Set<UUID>) {
        undoStack.removeAll { ids.contains($0.id) }
        updateUndoState()
    }

    private func rasterWritten(_ id: UUID) {
        encodingRasters.remove(id)
        pendingRasters[id] = nil
    }

    /// Saves everything and refreshes the first-page cover thumbnail when the notebook uses one.
    func close() {
        saveNow(wait: true)
        AppDiagnostics.log.info("notebook", "Closed \"\(notebook.title)\"")
        if notebook.cover == .firstPage, let first = notebook.pages.first,
           let png = renderer.image(of: first, rasters: rasterImages(for: first), maxPixels: 600).pngData() {
            try? store.saveThumbnail(png)
        }
    }

    func rename(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        mutate { $0.title = t }
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
            // Rendering a page for Vision takes a moment on the main thread: wait for a pause.
            if CACurrentMediaTime() - self.lastInkActivity < 2 { self.scheduleRecognition(); return }
            let ids = self.pagesNeedingRecognition
            self.pagesNeedingRecognition.removeAll()
            for id in ids {
                guard let page = self.notebook.pages.first(where: { $0.id == id }),
                      let image = self.renderer.inkImage(of: page, maxPixels: 2400).cgImage else { continue }
                let text: String
                do { text = try await HandwritingRecognizer.transcript(of: image, pageSize: page.size) } catch {
                    AppDiagnostics.log.warning("recognition", "Handwriting recognition failed: \(error.localizedDescription)")
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
        guard notebook.pages.indices.contains(proposal.pageIndex) else { throw AgentToolError.noSuchPage(proposal.pageIndex + 1) }
        beginEdit(pageID: notebook.pages[proposal.pageIndex].id)
        var copy = notebook
        try proposal.apply(to: &copy)
        mutate { $0 = copy }
    }

    func renderPage(_ index: Int, maxPixels: Int) async -> Data? {
        guard notebook.pages.indices.contains(index) else { return nil }
        let page = notebook.pages[index]
        return renderer.png(of: page, rasters: rasterImages(for: page), maxPixels: maxPixels)
    }

    func diagnosticsReport() async -> String? { AppDiagnostics.report() }

    func improvementNotes() async -> String? { ImprovementNotesModel.shared.plainText }

    func runSelfTest() async -> String? { await SelfTest.run() }

    func requestApproval(_ proposal: AgentProposal) async -> ApprovalDecision {
        // One proposal at a time: the agent loop runs tools sequentially.
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pageIndex = proposal.pageIndex   // show the user where the change would go
            pendingProposal = proposal
        }
    }
}
