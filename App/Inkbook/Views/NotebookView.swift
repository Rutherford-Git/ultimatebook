import SwiftUI
import InkbookCore

struct NotebookView: View {
    @ObservedObject var document: DocumentModel
    var close: () -> Void
    @State private var showLayers = false
    @State private var showAgent = false
    @State private var showAgentSettings = false
    @StateObject private var chat = AgentChatModel()
    @State private var exported: ExportedFile?
    @State private var exportError: String?
    @AppStorage("agent.enabled") private var agentEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            navigationRow
            toolRow
            Divider()
            CanvasView(document: document)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) { if !document.selection.isEmpty { selectionBar } }
        }
        .sheet(item: $exported) { ShareSheet(items: [$0.url]) }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: { Text(exportError ?? "") }
        .sheet(isPresented: $showLayers) { LayersPanel(document: document).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showAgent) {
            AgentPanel(document: document, chat: chat).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAgentSettings) { AgentSettingsView() }
        // Approvals are presented here only while the agent panel is closed; otherwise the panel shows them.
        .approvalSheet(for: document, enabled: !showAgent && !showAgentSettings)
    }

    /// Row 1: navigation, pages and notebook-level actions.
    private var navigationRow: some View {
        HStack(spacing: 4) {
            iconButton("chevron.left", label: "Library", action: close)
            Text(document.notebook.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 4)
            Spacer(minLength: 12)
            pageControls
            Divider().frame(height: 18).padding(.horizontal, 4)
            iconButton("square.3.layers.3d", label: "Layers") { showLayers = true }
            iconButton("square.and.arrow.up", label: "Export PDF") {
                document.saveNow()
                do { exported = ExportedFile(url: try document.exportPDF()) } catch { exportError = error.localizedDescription }
            }
            iconButton("sparkles", label: "Agent") {
                if agentEnabled, KeychainStore.load() != nil { showAgent = true } else { showAgentSettings = true }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
    }

    /// Row 2: drawing tools, color, size, undo/redo.
    private var toolRow: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { tool in
                Button { document.select(tool) } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 32, height: 30)
                        .background(document.tool == tool ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(tool.rawValue.capitalized)
            }
            Divider().frame(height: 18).padding(.horizontal, 6)
            ColorPicker("", selection: colorBinding, supportsOpacity: true)
                .labelsHidden()
                .scaleEffect(0.8)
                .frame(width: 30)
            Slider(value: sizeBinding, in: 0.5...80)
                .controlSize(.mini)
                .frame(width: 90)
            Text(String(format: "%.1f", document.brush.size))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Divider().frame(height: 18).padding(.horizontal, 6)
            iconButton("arrow.uturn.backward", label: "Undo") { document.undo() }.disabled(!document.canUndo)
            iconButton("arrow.uturn.forward", label: "Redo") { document.redo() }.disabled(!document.canRedo)
            Toggle(isOn: $document.pencilOnly) {
                Image(systemName: "applepencil").font(.system(size: 15))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .accessibilityLabel("Draw with Apple Pencil only")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 30)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private var selectionBar: some View {
        HStack(spacing: 20) {
            Text("\(document.selection.count) selected").font(.callout).foregroundStyle(.secondary)
            Button { document.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { document.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
            Button { document.clearSelection() } label: { Text("Done").bold() }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 20)
    }

    private var pageControls: some View {
        HStack(spacing: 0) {
            iconButton("chevron.up", label: "Previous page") { document.pageIndex -= 1 }.disabled(document.pageIndex == 0)
            Text("\(document.pageIndex + 1) / \(document.notebook.pages.count)")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 44)
            iconButton("chevron.down", label: "Next page") { document.pageIndex += 1 }
                .disabled(document.pageIndex >= document.notebook.pages.count - 1)
            iconButton("doc.badge.plus", label: "Add page") { document.addPage() }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(get: {
            let c = document.brush.color
            return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }, set: { color in
            let ui = UIColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            document.brushes[document.tool]?.color = RGBA(r, g, b, a)
        })
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { document.brush.size }, set: { document.brushes[document.tool]?.size = $0 })
    }
}

/// Identifiable wrapper so a proposal can drive `.sheet(item:)`.
struct ProposalBox: Identifiable, Equatable {
    let proposal: AgentProposal
    var id: String { proposal.summary }
}

extension View {
    func approvalSheet(for document: DocumentModel, enabled: Bool) -> some View {
        sheet(item: Binding(get: { enabled ? document.pendingProposal.map(ProposalBox.init) : nil },
                            set: { _ in })) { box in
            ApprovalSheet(proposal: box.proposal) { document.resolvePending($0) }
                .presentationDetents([.height(260)])
                .interactiveDismissDisabled()   // must answer Approve or Reject
        }
    }
}

struct ApprovalSheet: View {
    let proposal: AgentProposal
    let decide: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("The agent wants to change your notebook", systemImage: "sparkles").font(.headline)
            Text(proposal.summary).font(.body)
            Text("It will be added to the page's Agent layer, which you can hide or delete at any time.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Reject", role: .destructive) { decide(.reject(reason: nil)) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Approve") { decide(.approve) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}

struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// System share sheet (Save to Files, AirDrop, Mail, …) for exported files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
