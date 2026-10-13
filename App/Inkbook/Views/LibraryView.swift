import SwiftUI
import InkbookCore

enum LibrarySection: String, Hashable, CaseIterable {
    case all = "Notebooks", favorites = "Favorites"
    var symbol: String { self == .all ? "books.vertical" : "star" }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var section: LibrarySection? = .all
    @State private var search = ""
    @State private var importing = false
    @State private var showNew = false
    @State private var showAgentSettings = false
    @State private var open: OpenNotebook?
    @State private var openAfterSheet: OpenNotebook?
    @State private var renaming: LibraryStore.Entry?
    @State private var newTitle = ""

    private var visible: [LibraryStore.Entry] {
        library.entries
            .filter { section != .favorites || $0.info.isFavorite }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(LibrarySection.allCases, id: \.self) { s in
                    Label(s.rawValue, systemImage: s.symbol).tag(s)
                }
            }
            .navigationTitle("Inkbook")
            .safeAreaInset(edge: .bottom) {
                Button { showAgentSettings = true } label: {
                    Label("Agent", systemImage: "sparkles").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding()
            }
        } detail: {
            ScrollView {
                if visible.isEmpty { emptyState } else { grid }
            }
            .background(Color(Theme.backdrop))
            .navigationTitle(section?.rawValue ?? "Notebooks")
            .searchable(text: $search, prompt: "Search notebooks")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if library.isImporting { ProgressView() }
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    Button { showNew = true } label: { Label("New", systemImage: "plus").labelStyle(.titleAndIcon) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showNew, onDismiss: {
            // Open the new notebook only once the sheet is gone (presenting mid-dismiss is dropped).
            open = openAfterSheet
            openAfterSheet = nil
        }) {
            NewNotebookSheet { title, cover, paper in
                if let url = library.create(title: title, cover: cover, paper: paper) { openAfterSheet = OpenNotebook(url: url) }
            }
        }
        .sheet(isPresented: $showAgentSettings) { AgentSettingsView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [LibraryStore.goodnotesType, .pdf, .zip]) { result in
            if case .success(let url) = result { Task { await library.importFile(from: url) } }
        }
        .alert("Rename notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let r = renaming { library.rename(r, to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Imported", isPresented: Binding(get: { library.lastImportReport != nil },
                                                set: { if !$0 { library.lastImportReport = nil } })) {
            Button("OK") {}
        } message: {
            if let r = library.lastImportReport { Text(Self.describe(r)) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { library.errorMessage != nil },
                                                            set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(library.errorMessage ?? "") }
        .fullScreenCover(item: $open) { item in
            NotebookScreen(url: item.url).onDisappear { library.reload() }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 32)], spacing: 36) {
            ForEach(visible) { entry in
                NotebookCard(entry: entry,
                             open: { open = OpenNotebook(url: entry.url) },
                             favorite: { library.toggleFavorite(entry) },
                             rename: { newTitle = entry.title; renaming = entry },
                             setCover: { library.setCover(entry, $0) },
                             delete: { library.delete(entry) })
            }
        }
        .padding(32)
    }

    @ViewBuilder private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search).padding(.top, 80)
        } else if section == .favorites {
            ContentUnavailableView("No favorites yet", systemImage: "star",
                                   description: Text("Star a notebook from its menu to keep it here."))
                .padding(.top, 80)
        } else {
            VStack(spacing: 18) {
                Image(systemName: "book.closed").font(.system(size: 54, weight: .light)).foregroundStyle(Theme.accent)
                Text("Start your first notebook").font(.title2.weight(.semibold))
                Text("Write with Apple Pencil, paint on layers, and keep everything on this iPad.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                HStack(spacing: 12) {
                    Button { showNew = true } label: { Label("New notebook", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    Button { importing = true } label: { Label("Import PDF or Goodnotes", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
                .controlSize(.large)
            }
            .padding(.top, 120)
            .frame(maxWidth: .infinity)
        }
    }

    static func describe(_ r: ImportReport) -> String {
        var s = "\(r.pages) pages, \(r.strokes) strokes, \(r.images) images, \(r.textBoxes) text boxes."
        if r.outlinedStrokes + r.lines + r.stickyNotes > 0 {
            s += "\nIncludes \(r.outlinedStrokes) fountain-pen strokes, \(r.lines) lines and \(r.stickyNotes) sticky notes."
        }
        if !r.unsupported.isEmpty {
            s += "\nNot imported: " + r.unsupported.map { "\($0.value)× \($0.key)" }.sorted().joined(separator: ", ")
        }
        return s
    }
}

/// Cover, title and date, with a menu for notebook actions.
struct NotebookCard: View {
    let entry: LibraryStore.Entry
    let open: () -> Void
    let favorite: () -> Void
    let rename: () -> Void
    let setCover: (NotebookCover) -> Void
    let delete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 10) {
            Button(action: open) {
                CoverView(cover: entry.info.cover, title: entry.title, thumbnail: entry.thumbnail)
                    .overlay(alignment: .topTrailing) {
                        if entry.info.isFavorite {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                .padding(6).background(.ultraThinMaterial, in: Circle()).padding(8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .contextMenu { actions }

            Menu { actions } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    Text(entry.modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Delete “\(entry.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete notebook", role: .destructive, action: delete)
        } message: { Text("This removes the notebook and its pages from this iPad.") }
    }

    @ViewBuilder private var actions: some View {
        Button(action: favorite) {
            Label(entry.info.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: entry.info.isFavorite ? "star.slash" : "star")
        }
        Button(action: rename) { Label("Rename", systemImage: "pencil") }
        Menu {
            ForEach(0..<NotebookCover.paletteCount, id: \.self) { i in
                Button { setCover(.color(i)) } label: { Label(Self.coverNames[i], systemImage: "circle.fill") }
            }
            Button { setCover(.firstPage) } label: { Label("First page", systemImage: "doc.richtext") }
        } label: { Label("Cover", systemImage: "paintpalette") }
        Divider()
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
    }

    static let coverNames = ["Ink", "Forest", "Clay", "Plum", "Mustard", "Slate", "Rose", "Sand"]
}

/// One-screen setup: title, cover, paper. Sensible defaults so "Create" is always one tap away.
struct NewNotebookSheet: View {
    let create: (String, NotebookCover, Paper) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var coverIndex = 0
    @State private var style: PaperStyle = .ruled
    @State private var cream = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(alignment: .top, spacing: 24) {
                        CoverView(cover: .color(coverIndex), title: title.isEmpty ? "Untitled" : title)
                            .frame(width: 130)
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("Notebook title", text: $title)
                                .font(.title3.weight(.semibold))
                                .focused($titleFocused)
                                .submitLabel(.done)
                            Divider()
                            Text("Cover").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                ForEach(0..<NotebookCover.paletteCount, id: \.self) { i in
                                    Button { coverIndex = i } label: {
                                        Circle().fill(Theme.cover(i)).frame(width: 28, height: 28)
                                            .overlay(Circle().stroke(Theme.accent, lineWidth: coverIndex == i ? 3 : 0).padding(-4))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(NotebookCard.coverNames[i])
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Paper").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Picker("Tone", selection: $cream) {
                                Text("White").tag(false)
                                Text("Cream").tag(true)
                            }
                            .pickerStyle(.segmented).frame(width: 180)
                        }
                        HStack(spacing: 16) {
                            ForEach(PaperStyle.allCases) { s in
                                Button { style = s } label: {
                                    VStack(spacing: 6) {
                                        PaperPreview(style: s, tone: cream ? Theme.paperCream : Theme.paperWhite)
                                            .overlay(RoundedRectangle(cornerRadius: 8)
                                                .stroke(Theme.accent, lineWidth: style == s ? 3 : 0))
                                        Text(s.title).font(.caption).foregroundStyle(style == s ? Theme.accent : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(28)
            }
            .navigationTitle("New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        create(title, .color(coverIndex), style.paper(cream ? Theme.paperCream : Theme.paperWhite))
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium, .large])
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
            if let document { NotebookView(document: document) { document.close(); dismiss() } }
            else if let failure {
                ContentUnavailableView("Couldn’t open this notebook", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
                    .overlay(alignment: .topLeading) { Button("Close") { dismiss() }.padding() }
            } else { ProgressView() }
        }
        .task {
            do { document = try DocumentModel(store: NotebookStore(url: url)) } catch { failure = "\(error)" }
        }
    }
}
