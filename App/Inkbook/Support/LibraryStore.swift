import CoreGraphics
import Foundation
import UIKit
import InkbookCore
import UniformTypeIdentifiers

/// Notebooks live as `.inkbook` folders in the app's Documents directory — visible in the
/// Files app ("On My iPad › Inkbook"), never synced anywhere by the app itself.
@MainActor
final class LibraryStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let info: NotebookInfo
        var thumbnail: UIImage?
        var id: URL { url }
        var title: String { info.title }
        var modified: Date { info.modified }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var lastImportReport: ImportReport?
    @Published var errorMessage: String? {
        didSet { if let errorMessage { AppDiagnostics.log.error("library", errorMessage) } }
    }
    @Published private(set) var isImporting = false

    let root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() { reload() }

    /// Lists notebooks from their small `info.json` summaries (not the full manifests).
    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        entries = urls.filter { $0.pathExtension == "inkbook" }.compactMap { url in
            let store = NotebookStore(url: url)
            guard let info = try? store.loadInfo() else { return nil }
            let thumb = info.cover == .firstPage ? store.thumbnail().flatMap(UIImage.init(data:)) : nil
            return Entry(url: url, info: info, thumbnail: thumb)
        }.sorted { $0.modified > $1.modified }
    }

    @discardableResult
    func create(title: String, cover: NotebookCover, paper: Paper) -> URL? {
        do {
            let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : title
            let url = uniqueURL(for: name)
            _ = try NotebookStore.create(at: url, notebook: Notebook(title: name, pages: [Page(paper: paper)], cover: cover))
            reload()
            return url
        } catch {
            errorMessage = "Could not create notebook: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Editing notebooks from the library (rare: loads and saves the full notebook)

    private func edit(_ entry: Entry, _ change: (inout Notebook) -> Void) {
        let store = NotebookStore(url: entry.url)
        do {
            var nb = try store.load()
            change(&nb)
            try store.save(nb)
            if nb.cover == .firstPage, store.thumbnail() == nil { Self.renderThumbnail(nb, store: store) }
            reload()
        } catch {
            errorMessage = "Could not update notebook: \(error.localizedDescription)"
        }
    }

    func toggleFavorite(_ entry: Entry) { edit(entry) { $0.isFavorite.toggle() } }
    func rename(_ entry: Entry, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        edit(entry) { $0.title = t }
    }
    func setCover(_ entry: Entry, _ cover: NotebookCover) { edit(entry) { $0.cover = cover } }

    /// Renders the first page as the cover thumbnail.
    static func renderThumbnail(_ notebook: Notebook, store: NotebookStore) {
        guard let first = notebook.pages.first else { return }
        let image = PageRenderer(store: store).image(of: first, rasters: [:], maxPixels: 600)
        if let png = image.pngData() { try? store.saveThumbnail(png) }
    }

    /// Imports a file picked in the Files app: PDF, or a Goodnotes notebook.
    func importFile(from picked: URL) async {
        isImporting = true
        defer { isImporting = false }
        if picked.pathExtension.lowercased() == "pdf" { await importPDF(from: picked) }
        else { await importGoodnotes(from: picked) }
    }

    /// Creates a notebook with one page per PDF page (the PDF is the page background).
    func importPDF(from picked: URL) async {
        let accessed = picked.startAccessingSecurityScopedResource()
        defer { if accessed { picked.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: picked)
            guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else {
                errorMessage = "That file is not a readable PDF."; return
            }
            if doc.isEncrypted, !doc.unlockWithPassword("") {
                errorMessage = "The PDF is password-protected."; return
            }
            let pages = (0..<doc.numberOfPages).map { i -> PDFImport.PageInfo in
                guard let page = doc.page(at: i + 1) else { return PDFImport.PageInfo(size: Size(0, 0)) }
                let box = page.getBoxRect(.cropBox)
                let rotated = page.rotationAngle % 180 != 0
                return PDFImport.PageInfo(size: rotated ? Size(box.height, box.width) : Size(box.width, box.height))
            }
            let asset = "document.pdf"
            var notebook = try PDFImport.notebook(title: picked.deletingPathExtension().lastPathComponent, asset: asset, pages: pages)
            notebook.cover = .firstPage
            let store = try NotebookStore.create(at: uniqueURL(for: notebook.title), notebook: notebook)
            try store.saveAsset(data, named: asset)
            Self.renderThumbnail(notebook, store: store)
            reload()
        } catch {
            errorMessage = "PDF import failed: \(error)"
        }
    }

    /// Imports a `.goodnotes` file picked in the Files app. Runs off the main actor.
    func importGoodnotes(from picked: URL) async {
        let accessed = picked.startAccessingSecurityScopedResource()
        defer { if accessed { picked.stopAccessingSecurityScopedResource() } }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try GoodnotesImporter.importFile(at: picked)
            }.value
            var notebook = result.notebook
            notebook.cover = .firstPage
            let store = try NotebookStore.create(at: uniqueURL(for: notebook.title), notebook: notebook)
            for (name, data) in result.assets { try store.saveAsset(data, named: name) }
            Self.renderThumbnail(notebook, store: store)
            lastImportReport = result.report
            AppDiagnostics.log.log(result.report.warnings.isEmpty ? .info : .warning, "import",
                                   "Imported \"\(notebook.title)\" from Goodnotes. \(result.report)")
            reload()
        } catch {
            errorMessage = "Import failed: \(error)"
        }
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        reload()
    }

    private func uniqueURL(for title: String) -> URL {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        var url = root.appendingPathComponent("\(safe.isEmpty ? "Notebook" : safe).inkbook")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(safe) \(n).inkbook"); n += 1
        }
        return url
    }

    static let goodnotesType = UTType(filenameExtension: "goodnotes") ?? .zip
}
