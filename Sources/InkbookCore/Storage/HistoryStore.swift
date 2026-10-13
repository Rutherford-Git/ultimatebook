import Foundation

/// Persists a notebook's undo/redo history inside its bundle, so undo survives closing the app:
///
///     Title.inkbook/history/
///       index.json        { version, undo: [id], redo: [id] }   (oldest first)
///       <id>.json         one HistoryEntry
///       <id>.png          raster layer snapshot for that entry (optional)
///
/// Each edit writes one small entry file plus the index, never the whole history. Files not
/// referenced by the index are deleted, and the history is trimmed to the newest entries
/// within `maxEntries` / `maxBytes`.
public struct HistoryStore: Sendable {
    public static let version = 1
    public let directory: URL
    public let maxEntries: Int
    public let maxBytes: Int

    public init(bundle: URL, maxEntries: Int = 100, maxBytes: Int = 150 << 20) {
        directory = bundle.appendingPathComponent("history", isDirectory: true)
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    private struct Index: Codable {
        var version: Int
        var undo: [UUID]
        var redo: [UUID]
    }

    private func entryURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private func rasterURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public func write(_ entry: HistoryEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try NotebookStore.atomicWrite(try NotebookStore.encoder.encode(entry), to: entryURL(entry.id))
    }

    public func writeRaster(_ png: Data, for id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try NotebookStore.atomicWrite(png, to: rasterURL(id))
    }

    public func rasterData(for id: UUID) -> Data? { try? Data(contentsOf: rasterURL(id)) }

    public func hasEntry(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: entryURL(id).path) }

    /// Loads the persisted stacks (oldest first). Missing or unreadable entries are dropped,
    /// so a damaged history only loses those steps, never the notebook.
    public func load() -> (undo: [HistoryEntry], redo: [HistoryEntry]) {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? NotebookStore.decoder.decode(Index.self, from: data),
              index.version <= Self.version else { return ([], []) }
        func entries(_ ids: [UUID]) -> [HistoryEntry] {
            ids.compactMap { id in
                (try? Data(contentsOf: entryURL(id))).flatMap { try? NotebookStore.decoder.decode(HistoryEntry.self, from: $0) }
            }
        }
        return (entries(index.undo), entries(index.redo))
    }

    /// Writes the index for the given stacks after trimming, deletes unreferenced files, and
    /// returns the ids dropped from the bottom of the undo stack (so the caller can forget them).
    @discardableResult
    public func saveIndex(undo: [UUID], redo: [UUID]) throws -> [UUID] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keptUndo = Array(undo.suffix(maxEntries))
        let keptRedo = Array(redo.suffix(maxEntries))
        // Byte budget: keep redo and the newest undo steps; drop the oldest undo steps first.
        var total = keptRedo.reduce(0) { $0 + size(of: $1) }
        var budgeted: [UUID] = []
        for id in keptUndo.reversed() {
            total += size(of: id)
            if total > maxBytes { break }
            budgeted.append(id)
        }
        keptUndo = budgeted.reversed()
        let dropped = undo.filter { !keptUndo.contains($0) }

        let index = Index(version: Self.version, undo: keptUndo, redo: keptRedo)
        try NotebookStore.atomicWrite(try NotebookStore.encoder.encode(index), to: indexURL)
        collectGarbage(keeping: Set(keptUndo + keptRedo))
        return dropped
    }

    private func size(of id: UUID) -> Int {
        [entryURL(id), rasterURL(id)].reduce(0) { sum, url in
            sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
    }

    private func collectGarbage(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in files where name != "index.json" {
            let stem = (name as NSString).deletingPathExtension
            if let id = UUID(uuidString: stem), ids.contains(id) { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
