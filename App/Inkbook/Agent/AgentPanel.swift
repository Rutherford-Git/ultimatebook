import SwiftUI
import InkbookCore

/// Chat with the agent about the open notebook. Off by default; nothing leaves the device
/// until the user enables the agent, saves their own API key and sends a message.
struct AgentPanel: View {
    @ObservedObject var document: DocumentModel
    @ObservedObject var chat: AgentChatModel
    @State private var input = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(chat.lines) { line in
                                Text(line.text)
                                    .padding(10)
                                    .background(line.fromUser ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .frame(maxWidth: .infinity, alignment: line.fromUser ? .trailing : .leading)
                                    .id(line.id)
                            }
                            if chat.isWorking { ProgressView().padding() }
                        }
                        .padding()
                    }
                    .onChange(of: chat.lines.count) { proxy.scrollTo(chat.lines.last?.id) }
                }
                Divider()
                HStack {
                    TextField("Ask about this notebook…", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button {
                        let text = input; input = ""
                        Task { await chat.send(text, host: document) }
                    } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || chat.isWorking)
                }
                .padding()
            }
            .navigationTitle("Agent")
            .toolbar {
                Button { chat.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { AgentSettingsView() }
            .approvalSheet(for: document, enabled: !showSettings)
            .onAppear { if KeychainStore.load() == nil { showSettings = true } }
        }
    }
}

@MainActor
final class AgentChatModel: ObservableObject {
    struct Line: Identifiable { let id = UUID(); let text: String; let fromUser: Bool }

    @Published var lines: [Line] = []
    @Published var isWorking = false
    private var session: AgentSession?
    private var sessionKey: String?

    func reset() {
        lines.removeAll()
        session = nil
    }

    func send(_ text: String, host: DocumentModel) async {
        guard let key = KeychainStore.load(), !key.isEmpty else {
            lines.append(Line(text: "Add an API key in Agent settings first.", fromUser: false)); return
        }
        if session == nil || sessionKey != key {
            let defaults = UserDefaults.standard
            let config = AgentConfiguration(
                model: defaults.string(forKey: "agent.model") ?? AgentConfiguration.default.model,
                effort: defaults.string(forKey: "agent.effort") ?? AgentConfiguration.default.effort)
            session = AgentSession(transport: AnthropicHTTPTransport(apiKey: key), host: host, configuration: config)
            sessionKey = key
        }
        lines.append(Line(text: text, fromUser: true))
        isWorking = true
        defer { isWorking = false }
        do {
            let reply = try await session!.send(text)
            var message = reply.text.isEmpty ? "(no text reply)" : reply.text
            switch reply.ending {
            case .completed: break
            case .truncated: message += "\n\n[Reply was cut off.]"
            case .iterationLimit: message += "\n\n[Stopped after too many steps.]"
            case .refused(let category, _): message += "\n\n[The request was declined\(category.map { " (\($0))" } ?? "").]"
            }
            lines.append(Line(text: message, fromUser: false))
        } catch {
            lines.append(Line(text: "\(error)", fromUser: false))
        }
    }
}

struct AgentSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("agent.enabled") private var enabled = false
    @AppStorage("agent.model") private var model = AgentConfiguration.default.model
    @AppStorage("agent.effort") private var effort = AgentConfiguration.default.effort
    @State private var key = ""
    @State private var hasKey = KeychainStore.load() != nil
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enable agent", isOn: $enabled)
                } footer: {
                    Text("When enabled, pages you ask about (text, and page images when the agent requests them) are sent to the API endpoint using your own key. Nothing is sent otherwise. Every change the agent proposes needs your approval and goes on a separate Agent layer.")
                }
                Section("API key") {
                    SecureField(hasKey ? "Saved — enter a new key to replace" : "sk-ant-…", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save key") {
                        do { try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; hasKey = true }
                        catch { self.error = "Could not save key: \(error.localizedDescription)" }
                    }.disabled(key.isEmpty)
                    if hasKey {
                        Button("Remove key", role: .destructive) { KeychainStore.delete(); hasKey = false }
                    }
                }
                Section("Model") {
                    TextField("Model", text: $model).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Picker("Effort", selection: $effort) {
                        ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Agent settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
