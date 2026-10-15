import Foundation

/// Errors from reading or writing a `.inkbook` bundle.
public enum StoreError: Error, Equatable, CustomStringConvertible {
    case notABundle(String)
    case unsupportedSchema(found: Int, supported: Int)
    case corrupt(String, reason: String)
    case invalidName(String)

    public var description: String {
        switch self {
        case .notABundle(let p): "Not an Inkbook bundle: \(p)"
        case .unsupportedSchema(let f, let s): "Notebook schema \(f) is newer than supported \(s)"
        case .corrupt(let p, let r): "Corrupt file \(p): \(r)"
        case .invalidName(let n): "Invalid asset or layer name: \(n)"
        }
    }
}

/// On-disk layout of a notebook — a plain directory, local only, no cloud:
///
///     Title.inkbook/
///       manifest.json          { schemaVersion, notebook (pages without layer bitmaps) }
///       raster/<layerId>.png   Procreate-style layer bitmaps
///       assets/<name>          imported images / PDFs
///
/// Every file is written atomically (temp file + replace), so a crash never leaves a
/// half-written manifest. Bitmaps are stored separately so saving vector edits does not
/// rewrite large PNGs.
public struct NotebookStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    private var manifestURL: URL { url.appendingPathComponent("manifest.json") }
    public var assetsURL: URL { url.appendingPathComponent("assets", isDirectory: true) }
    public var rasterURL: URL { url.appendingPathComponent("raster", isDirectory: true) }

    private struct Manifest: Codable {
        var schemaVersion: Int
        var notebook: Notebook
    }

    // MARK: Notebook

    public static func create(at url: URL, notebook: Notebook) throws -> NotebookStore {
        let store = NotebookStore(url: url)
        try FileManager.default.createDirectory(at: store.assetsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.rasterURL, withIntermediateDirectories: true)
        try store.save(notebook)
        return store
    }

    public func load() throws -> Notebook {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw StoreError.notABundle(url.path)
        }
        let data = try Data(contentsOf: manifestURL)
        // Read the version before decoding the whole notebook so a newer file fails clearly.
        struct Version: Decodable { var schemaVersion: Int }
        let version: Version
        do { version = try JSONDecoder().decode(Version.self, from: data) } catch {
            throw StoreError.corrupt("manifest.json", reason: "\(error)")
        }
        guard version.schemaVersion <= Notebook.schemaVersion else {
            throw StoreError.unsupportedSchema(found: version.schemaVersion, supported: Notebook.schemaVersion)
        }
        do { return try Self.decoder.decode(Manifest.self, from: data).notebook } catch {
            throw StoreError.corrupt("manifest.json", reason: "\(error)")
        }
    }

    public func save(_ notebook: Notebook) throws {
        let data = try Self.encoder.encode(Manifest(schemaVersion: Notebook.schemaVersion, notebook: notebook))
        try Self.atomicWrite(data, to: manifestURL)
        try Self.atomicWrite(try Self.encoder.encode(notebook.info), to: infoURL)
        try Self.atomicWrite(try Self.encoder.encode(SearchIndex(notebook)), to: searchURL)
    }

    private var searchURL: URL { url.appendingPathComponent("search.json") }

    /// Page texts for library search, without loading the notebook. Built from the manifest
    /// for bundles saved before the index existed.
    public func loadSearchIndex() -> SearchIndex? {
        if let data = try? Data(contentsOf: searchURL), let index = try? Self.decoder.decode(SearchIndex.self, from: data) {
            return index
        }
        guard let notebook = try? load() else { return nil }
        let index = SearchIndex(notebook)
        if let data = try? Self.encoder.encode(index) { try? Self.atomicWrite(data, to: searchURL) }
        return index
    }

    private var infoURL: URL { url.appendingPathComponent("info.json") }
    private var thumbnailURL: URL { url.appendingPathComponent("thumbnail.png") }

    /// Library summary. Falls back to the full manifest for bundles saved before `info.json`
    /// existed (and writes the summary so the next listing is fast).
    public func loadInfo() throws -> NotebookInfo {
        if let data = try? Data(contentsOf: infoURL), let info = try? Self.decoder.decode(NotebookInfo.self, from: data) {
            return info
        }
        let info = try load().info
        try? Self.atomicWrite(try Self.encoder.encode(info), to: infoURL)
        return info
    }

    /// First-page thumbnail used as a cover (rendered by the app).
    public func thumbnail() -> Data? { try? Data(contentsOf: thumbnailURL) }

    public func saveThumbnail(_ png: Data) throws { try Self.atomicWrite(png, to: thumbnailURL) }

    // MARK: Raster layers and assets

    public func rasterData(for layerID: UUID) -> Data? {
        try? Data(contentsOf: rasterURL.appendingPathComponent("\(layerID.uuidString).png"))
    }

    public func saveRaster(_ png: Data, for layerID: UUID) throws {
        try FileManager.default.createDirectory(at: rasterURL, withIntermediateDirectories: true)
        try Self.atomicWrite(png, to: rasterURL.appendingPathComponent("\(layerID.uuidString).png"))
    }

    public func assetData(named name: String) throws -> Data {
        try Data(contentsOf: assetURL(name))
    }

    public func saveAsset(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try Self.atomicWrite(data, to: assetURL(name))
    }

    /// Asset names are single path components; anything else could escape the bundle.
    private func assetURL(_ name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw StoreError.invalidName(name)
        }
        return assetsURL.appendingPathComponent(name)
    }

    // MARK: Helpers

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        // rename(2) atomically replaces the destination on the same volume (Apple + Linux).
        guard rename(tmp.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path,
                                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }
}
