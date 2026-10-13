import Foundation

public struct AgentConfiguration: Equatable, Sendable {
    public var model: String
    public var maxTokens: Int
    /// `low` | `medium` | `high` | `xhigh` | `max`.
    public var effort: String
    /// Re-run a declined request on Anthropic's default fallback model inside the same call.
    public var refusalFallback: Bool
    /// Safety valve on model round trips per user message.
    public var maxIterations: Int

    public init(model: String = "claude-opus-5-5", maxTokens: Int = 16000, effort: String = "medium",
                refusalFallback: Bool = true, maxIterations: Int = 24) {
        self.model = model; self.maxTokens = maxTokens; self.effort = effort
        self.refusalFallback = refusalFallback; self.maxIterations = maxIterations
    }

    public static let `default` = AgentConfiguration()

    /// Models offered in settings (current generation), default first.
    public static let knownModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]

    /// Server-side refusal fallback (`fallbacks: "default"`) is only accepted by these models;
    /// sending it to others (e.g. Haiku 5.5) is rejected.
    public static let refusalFallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-5"]

    /// Whether requests include the refusal fallback for this configuration.
    public var sendsRefusalFallback: Bool { refusalFallback && Self.refusalFallbackModels.contains(model) }
}

/// Outcome of one user message.
public struct AgentReply: Equatable, Sendable {
    public enum Ending: Equatable, Sendable {
        case completed
        case truncated            // hit max_tokens
        case refused(category: String?, explanation: String?)
        case iterationLimit
    }

    public var text: String
    public var ending: Ending
    public var toolCalls: [String]
}

/// Manual tool-use loop over the Messages API. Conversation state is append-only: assistant
/// content (including thinking and fallback blocks) is echoed back exactly as received.
public actor AgentSession {
    public static let systemPrompt = """
    You are a study and drawing assistant inside Inkbook, a local notebook and painting app on the \
    user's iPad. You can read the open notebook with list_pages and read_page, and propose annotations \
    with add_note and add_highlight. Every annotation is shown to the user for approval first and goes \
    on a separate Agent layer they can hide or delete. Handwriting transcripts are machine-recognized \
    and often wrong on math and diagrams; request the page image when accuracy matters. Prefer few, \
    well-placed annotations in empty space near the content they refer to. If a request is ambiguous, \
    answer in chat instead of annotating.
    """

    private let transport: MessagesTransport
    private let configuration: AgentConfiguration
    /// Weak: the host (the open document's view model) owns the session, not the reverse.
    private weak var host: AgentNotebookHost?
    public private(set) var messages: [JSONValue] = []

    public init(transport: MessagesTransport, host: AgentNotebookHost, configuration: AgentConfiguration = .default) {
        self.transport = transport; self.host = host; self.configuration = configuration
    }

    public func reset() { messages.removeAll() }

    public func send(_ userText: String) async throws -> AgentReply {
        guard let host else { throw AgentToolError.notebookClosed }
        messages.append(["role": "user", "content": [["type": "text", "text": .string(userText)]]])
        var toolCalls: [String] = []
        var texts: [String] = []

        for _ in 0..<configuration.maxIterations {
            let response = try await transport.send(requestBody())
            guard let content = response["content"]?.array, let stop = response["stop_reason"]?.string else {
                throw AgentAPIError.malformedResponse
            }
            messages.append(["role": "assistant", "content": .array(content)])
            texts += content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
            let toolUses = content.filter { $0["type"]?.string == "tool_use" }

            switch stop {
            case "tool_use":
                var results: [JSONValue] = []
                for use in toolUses {   // sequential: write tools wait for user approval one at a time
                    let name = use["name"]?.string ?? ""
                    toolCalls.append(name)
                    let output = await NotebookTools.run(name, input: use["input"] ?? [:], host: host)
                    results.append(toolResult(id: use["id"]?.string ?? "", output))
                }
                messages.append(["role": "user", "content": .array(results)])   // all results in one message
            case "pause_turn":
                continue   // resend as-is to let the model continue
            case "max_tokens":
                closeDanglingToolUses(toolUses, reason: "Not run: the response was cut off at max_tokens.")
                return AgentReply(text: texts.joined(separator: "\n\n"), ending: .truncated, toolCalls: toolCalls)
            case "refusal":
                closeDanglingToolUses(toolUses, reason: "Not run: the request was declined.")
                let details = response["stop_details"]
                return AgentReply(text: texts.joined(separator: "\n\n"),
                                  ending: .refused(category: details?["category"]?.string,
                                                   explanation: details?["explanation"]?.string),
                                  toolCalls: toolCalls)
            default:   // end_turn, stop_sequence
                return AgentReply(text: texts.joined(separator: "\n\n"), ending: .completed, toolCalls: toolCalls)
            }
        }
        return AgentReply(text: texts.joined(separator: "\n\n"), ending: .iterationLimit, toolCalls: toolCalls)
    }

    func requestBody() -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(configuration.model),
            "max_tokens": .number(Double(configuration.maxTokens)),
            "system": .string(Self.systemPrompt),
            "tools": .array(NotebookTools.definitions),
            "messages": .array(messages),
            "output_config": ["effort": .string(configuration.effort)],
            // Caches tools + system + history prefix across the loop's round trips.
            "cache_control": ["type": "ephemeral"],
        ]
        if configuration.sendsRefusalFallback { body["fallbacks"] = "default" }
        return .object(body)
    }

    private func toolResult(id: String, _ output: ToolOutput) -> JSONValue {
        var content: [JSONValue] = [["type": "text", "text": .string(output.text)]]
        if let png = output.png {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": "image/png", "data": .string(png.base64EncodedString())]])
        }
        var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": .array(content)]
        if output.isError { block["is_error"] = true }
        return .object(block)
    }

    /// Every tool_use must be answered before the next user turn, even when we stop early.
    private func closeDanglingToolUses(_ uses: [JSONValue], reason: String) {
        guard !uses.isEmpty else { return }
        messages.append(["role": "user", "content": .array(uses.map {
            ["type": "tool_result", "tool_use_id": $0["id"] ?? "", "content": .string(reason), "is_error": true]
        })])
    }
}
