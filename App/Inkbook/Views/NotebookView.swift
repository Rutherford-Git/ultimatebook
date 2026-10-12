import SwiftUI
import InkbookCore

struct NotebookView: View {
    @ObservedObject var document: DocumentModel
    var close: () -> Void
    @State private var showLayers = false
    @State private var showAgent = false
    @StateObject private var chat = AgentChatModel()
    @AppStorage("agent.enabled") private var agentEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            CanvasView(document: document)
                .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: $showLayers) { LayersPanel(document: document).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showAgent) {
            AgentPanel(document: document, chat: chat).presentationDetents([.medium, .large])
        }
        // Approvals are presented here only while the agent panel is closed; otherwise the panel shows them.
        .approvalSheet(for: document, enabled: !showAgent)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: close) { Image(systemName: "chevron.left") }
            Text(document.notebook.title).font(.headline).lineLimit(1)
            Spacer()
            ForEach(Tool.allCases) { tool in
                Button { document.select(tool) } label: {
                    Image(systemName: tool.symbol)
                        .padding(6)
                        .background(document.tool == tool ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityLabel(tool.rawValue.capitalized)
            }
            ColorPicker("", selection: colorBinding, supportsOpacity: true).labelsHidden().frame(width: 32)
            Slider(value: sizeBinding, in: 0.5...80).frame(width: 110)
            Divider().frame(height: 24)
            Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!document.canUndo)
            Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!document.canRedo)
            Toggle(isOn: $document.pencilOnly) { Image(systemName: "applepencil") }.toggleStyle(.button)
            Button { showLayers = true } label: { Image(systemName: "square.3.layers.3d") }
            pageControls
            if agentEnabled {
                Button { showAgent = true } label: { Image(systemName: "sparkles") }
                    .accessibilityLabel("Agent")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var pageControls: some View {
        HStack(spacing: 6) {
            Button { document.pageIndex -= 1 } label: { Image(systemName: "chevron.up") }.disabled(document.pageIndex == 0)
            Text("\(document.pageIndex + 1)/\(document.notebook.pages.count)").monospacedDigit().font(.caption)
            Button { document.pageIndex += 1 } label: { Image(systemName: "chevron.down") }
                .disabled(document.pageIndex >= document.notebook.pages.count - 1)
            Button { document.addPage() } label: { Image(systemName: "doc.badge.plus") }
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
