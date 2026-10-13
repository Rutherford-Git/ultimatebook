import SwiftUI
import InkbookCore

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
