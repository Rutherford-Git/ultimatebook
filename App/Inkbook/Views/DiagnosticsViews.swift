import SwiftUI
import InkbookCore

/// Errors, crash reports, ink timings and the self-test, in one place. Everything here can be
/// copied or shared as plain text, and the agent reads the same report with `read_diagnostics`.
struct DiagnosticsView: View {
    @AppStorage("diag.hud") private var hud = false
    @AppStorage("diag.legacyLiveInk") private var legacyLiveInk = false
    @State private var entries: [DiagnosticsLog.Entry] = DiagnosticsLog.shared.entries
    @State private var problemsOnly = false
    @State private var running = false
    @State private var lastReport: String?
    @State private var shared: ExportedFile?
    @State private var observer: UUID?

    private var shown: [DiagnosticsLog.Entry] {
        entries.reversed().filter { !problemsOnly || $0.level != .info }
    }

    var body: some View {
        List {
            Section {
                Button {
                    running = true
                    Task { lastReport = await SelfTest.run(); running = false }
                } label: {
                    HStack {
                        Label(running ? "Running self-test…" : "Run self-test", systemImage: "checkmark.seal")
                        if running { Spacer(); ProgressView() }
                    }
                }
                .disabled(running)
                if let lastReport {
                    CopyableText(text: lastReport)
                }
            } header: { Text("Self-test") } footer: {
                Text("Runs on a scratch notebook: an ink benchmark (current vs previous live renderer at 10, 40 and 80 strokes) plus save, undo, lasso, paint, PDF and agent checks. The agent can run it too.")
            }

            Section {
                Toggle("Show ink timing overlay", isOn: $hud)
                Toggle("Use previous live-ink renderer", isOn: $legacyLiveInk)
                ForEach(PerfRecorder.shared.summaries(), id: \.name) { s in
                    Text(s.line).font(.caption.monospacedDigit()).textSelection(.enabled)
                }
            } header: { Text("Ink performance") } footer: {
                Text("Switch the renderer, scribble the same thing, and compare the overlay numbers for a before/after on your iPad.")
            }

            Section {
                Picker("Show", selection: $problemsOnly) {
                    Text("Everything").tag(false)
                    Text("Errors and warnings").tag(true)
                }
                .pickerStyle(.segmented)
                if shown.isEmpty {
                    Text("Nothing logged.").foregroundStyle(.secondary)
                }
                ForEach(shown) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(entry.level)).foregroundStyle(color(entry.level))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message).font(.callout)
                            Text("\(entry.category) · \(entry.date.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.line } }
                }
            } header: { Text("Log") }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { UIPasteboard.general.string = AppDiagnostics.report(limit: 200) } label: {
                    Label("Copy report", systemImage: "doc.on.doc")
                }
                Button { shared = TextExport.file(AppDiagnostics.report(limit: 400), name: "Inkbook diagnostics") } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Menu {
                    Button("Clear log", systemImage: "trash", role: .destructive) { DiagnosticsLog.shared.clear(); refresh() }
                    Button("Reset ink timings", systemImage: "gauge.with.dots.needle.0percent") { PerfRecorder.shared.reset(); refresh() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
        .onAppear {
            refresh()
            observer = DiagnosticsLog.shared.observe { Task { @MainActor in refresh() } }
        }
        .onDisappear { if let observer { DiagnosticsLog.shared.removeObserver(observer) } }
    }

    private func refresh() { entries = DiagnosticsLog.shared.entries }

    private func icon(_ level: DiagnosticsLog.Level) -> String {
        switch level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func color(_ level: DiagnosticsLog.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Your running list of things to improve in the app.
struct ImprovementNotesView: View {
    @ObservedObject private var model = ImprovementNotesModel.shared
    @State private var draft = ""
    @State private var category: ImprovementNote.Category = .bug
    @State private var showDone = false
    @State private var editing: ImprovementNote?
    @State private var shared: ExportedFile?
    @FocusState private var composing: Bool

    private var shown: [ImprovementNote] { model.notes.filter { showDone || !$0.isDone } }

    var body: some View {
        List {
            Section {
                TextField("What should be better?", text: $draft, axis: .vertical)
                    .lineLimit(2...8)
                    .focused($composing)
                HStack {
                    Picker("Type", selection: $category) {
                        ForEach(ImprovementNote.Category.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    PasteButton(payloadType: String.self) { strings in
                        draft += (draft.isEmpty ? "" : "\n") + strings.joined(separator: "\n")
                    }
                    .labelStyle(.iconOnly)
                    Button("Add") {
                        model.add(draft, category: category, context: nil)
                        draft = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("Notes stay on this iPad. The agent can read them (ask it to review your notes), and Copy or Share gives you plain text.")
            }

            Section {
                Toggle("Show done", isOn: $showDone)
                if shown.isEmpty {
                    Text(model.notes.isEmpty ? "No notes yet." : "Everything is done.").foregroundStyle(.secondary)
                }
                ForEach(shown) { note in
                    NoteRow(note: note) { model.update($0) }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = note }
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = note.text }
                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete([note.id]) }
                        }
                }
                .onDelete { offsets in model.delete(Set(offsets.map { shown[$0].id })) }
            } header: { Text("\(model.notes.filter { !$0.isDone }.count) open") }
        }
        .navigationTitle("Improvement notes")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { UIPasteboard.general.string = model.plainText } label: { Label("Copy all", systemImage: "doc.on.doc") }
                Button { shared = TextExport.file(model.plainText, name: "Inkbook improvement notes") } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $editing) { note in NoteEditor(note: note) { model.update($0) } }
        .sheet(item: $shared) { ShareSheet(items: [$0.url]) }
    }
}

private struct NoteRow: View {
    let note: ImprovementNote
    let update: (ImprovementNote) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                var n = note
                n.isDone.toggle()
                update(n)
            } label: {
                Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(note.isDone ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.isDone ? "Mark as open" : "Mark as done")
            VStack(alignment: .leading, spacing: 4) {
                Text(note.text).strikethrough(note.isDone).foregroundStyle(note.isDone ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(note.category.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                    Text(note.created.formatted(date: .abbreviated, time: .shortened))
                    if let context = note.context { Text("· \(context)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct NoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var note: ImprovementNote
    let save: (ImprovementNote) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Note", text: $note.text, axis: .vertical).lineLimit(3...12)
                Picker("Type", selection: $note.category) {
                    ForEach(ImprovementNote.Category.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Done", isOn: $note.isDone)
            }
            .navigationTitle("Edit note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(note); dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Quick capture from the writing screen; the notebook and page are attached automatically.
struct QuickNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: String
    @State private var text = ""
    @State private var category: ImprovementNote.Category = .bug
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should be better?", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .focused($focused)
                    Picker("Type", selection: $category) {
                        ForEach(ImprovementNote.Category.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: { Text("Saved to Improvement notes with “\(context)”.") }
            }
            .navigationTitle("Improvement note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        ImprovementNotesModel.shared.add(text, category: category, context: context)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

/// Small live readout of ink timings over the canvas (Diagnostics › Show ink timing overlay).
struct InkHUD: View {
    let elementCount: Int

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(InkPerf.legacyLiveInk ? "previous" : "current") renderer · \(elementCount) elements")
                ForEach([InkPerf.liveDraw, InkPerf.frame, InkPerf.commit, InkPerf.pageDraw], id: \.self) { name in
                    if let s = PerfRecorder.shared.summary(name) {
                        Text(String(format: "%@ p50 %.2f · p95 %.2f ms", name, s.p50, s.p95))
                    }
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .allowsHitTesting(false)
        }
    }
}

/// Selectable text with a copy button.
struct CopyableText: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.caption.monospaced()).textSelection(.enabled)
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = text
                copied = true
            }
            .font(.callout)
        }
    }
}

enum TextExport {
    /// Writes text to a temporary .txt file for the share sheet.
    static func file(_ text: String, name: String) -> ExportedFile? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ExportedFile(url: url)
        } catch {
            AppDiagnostics.log.error("export", "Could not write \(name).txt: \(error.localizedDescription)")
            return nil
        }
    }
}
