import CoreGraphics
import Foundation
import InkbookCore
import UniformTypeIdentifiers

/// Notebooks live as `.inkbook` folders in the app's Documents directory — visible in the
/// Files app ("On My iPad › Inkbook"), never synced anywhere by the app itself.
@MainActor
final class LibraryStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let title: String
        let modified: Date
        var id: URL { url }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var lastImportReport: ImportReport?
    @Published var errorMessage: String?

    let root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    init() { reload() }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        entries = urls.filter { $0.pathExtension == "inkbook" }.compactMap { url in
            guard let nb = try? NotebookStore(url: url).load() else { return nil }
            return Entry(url: url, title: nb.title, modified: nb.modified)
        }.sorted { $0.modified > $1.modified }
    }

    @discardableResult
    func create(title: String, paper: Paper = .ruled(.white, spacing: 34)) -> URL? {
        do {
            let url = uniqueURL(for: title)
            _ = try NotebookStore.create(at: url, notebook: Notebook(title: title, pages: [Page(paper: paper)]))
            reload()
            return url
        } catch {
            errorMessage = "Could not create notebook: \(error.localizedDescription)"
            return nil
        }
    }

    /// Imports a file picked in the Files app: PDF, or a Goodnotes notebook.
    func importFile(from picked: URL) async {
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
            let notebook = try PDFImport.notebook(title: picked.deletingPathExtension().lastPathComponent, asset: asset, pages: pages)
            let store = try NotebookStore.create(at: uniqueURL(for: notebook.title), notebook: notebook)
            try store.saveAsset(data, named: asset)
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
            let url = uniqueURL(for: result.notebook.title)
            let store = try NotebookStore.create(at: url, notebook: result.notebook)
            for (name, data) in result.assets { try store.saveAsset(data, named: name) }
            lastImportReport = result.report
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
