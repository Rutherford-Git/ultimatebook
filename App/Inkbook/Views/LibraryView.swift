import SwiftUI
import InkbookCore

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var importing = false
    @State private var newTitle = ""
    @State private var askingTitle = false
    @State private var open: OpenNotebook?
    @State private var showAgentSettings = false

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 24)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(library.entries) { entry in
                        Button { open = OpenNotebook(url: entry.url) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.secondarySystemBackground))
                                    .aspectRatio(0.77, contentMode: .fit)
                                    .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
                                Text(entry.title).font(.headline).lineLimit(1)
                                Text(entry.modified, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete", role: .destructive) { library.delete(entry) }
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Inkbook")
            .toolbar {
                Button { importing = true } label: { Label("Import Goodnotes", systemImage: "square.and.arrow.down") }
                Button { askingTitle = true } label: { Label("New Notebook", systemImage: "plus") }
                Button { showAgentSettings = true } label: { Label("Agent", systemImage: "sparkles") }
            }
            .sheet(isPresented: $showAgentSettings) { AgentSettingsView() }
            .alert("New notebook", isPresented: $askingTitle) {
                TextField("Title", text: $newTitle)
                Button("Create") { open = library.create(title: newTitle.isEmpty ? "Untitled" : newTitle).map(OpenNotebook.init); newTitle = "" }
                Button("Cancel", role: .cancel) {}
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [LibraryStore.goodnotesType, .zip]) { result in
                if case .success(let url) = result { Task { await library.importGoodnotes(from: url) } }
            }
            .alert("Imported", isPresented: Binding(get: { library.lastImportReport != nil },
                                                    set: { if !$0 { library.lastImportReport = nil } })) {
                Button("OK") {}
            } message: {
                if let r = library.lastImportReport { Text(Self.describe(r)) }
            }
            .alert("Error", isPresented: Binding(get: { library.errorMessage != nil },
                                                 set: { if !$0 { library.errorMessage = nil } })) {
                Button("OK") {}
            } message: { Text(library.errorMessage ?? "") }
            .fullScreenCover(item: $open) { item in
                NotebookScreen(url: item.url).onDisappear { library.reload() }
            }
        }
    }

    static func describe(_ r: ImportReport) -> String {
        var s = "\(r.pages) pages, \(r.strokes) strokes, \(r.images) images, \(r.textBoxes) text boxes."
        if r.approximatedStrokes > 0 { s += "\n\(r.approximatedStrokes) fountain-pen strokes imported at constant width." }
        if !r.unsupported.isEmpty {
            s += "\nNot imported: " + r.unsupported.map { "\($0.value)× \($0.key)" }.sorted().joined(separator: ", ")
        }
        return s
    }
}

struct OpenNotebook: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Opens a notebook bundle and shows it, or an error if it cannot be read.
struct NotebookScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var document: DocumentModel?
    @State private var failure: String?

    var body: some View {
        Group {
            if let document { NotebookView(document: document) { document.saveNow(); dismiss() } }
            else if let failure {
                VStack(spacing: 12) { Text(failure); Button("Close") { dismiss() } }
            } else { ProgressView() }
        }
        .task {
            do { document = try DocumentModel(store: NotebookStore(url: url)) } catch { failure = "\(error)" }
        }
    }
}
