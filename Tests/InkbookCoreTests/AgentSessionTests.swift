import XCTest
@testable import InkbookCore

final class AgentSessionTests: XCTestCase {
    func notebook() -> Notebook {
        var nb = Notebook(title: "Physics 2", pages: [Page(recognizedText: "F = qE"), Page()])
        nb.pages[0].layers[0].elements = [.text(TextBox(frame: Rect(x: 10, y: 20, width: 200, height: 40), text: "Coulomb's law"))]
        return nb
    }

    func testRequestShapeToolsAndDefaults() async throws {
        let transport = ScriptedTransport([assistant([["type": "text", "text": "Hi"]], stop: "end_turn")])
        let host = FakeHost(notebook())
        let session = AgentSession(transport: transport, host: host)
        let reply = try await session.send("hello")
        XCTAssertEqual(reply, AgentReply(text: "Hi", ending: .completed, toolCalls: []))

        let body = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(body["model"]?.string, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"]?.number, 16000)
        XCTAssertEqual(body["fallbacks"]?.string, "default")
        XCTAssertEqual(body["output_config"]?["effort"]?.string, "medium")
        XCTAssertNil(body["thinking"])        // Opus 5.5: adaptive by default
        XCTAssertNil(body["tool_choice"])     // forced tool choice is rejected on this model
        let tools = try XCTUnwrap(body["tools"]?.array)
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["list_pages", "read_page", "add_note", "add_highlight"])
        for tool in tools {
            XCTAssertEqual(tool["strict"]?.bool, true)
            XCTAssertEqual(tool["input_schema"]?["additionalProperties"]?.bool, false)
            let props = tool["input_schema"]?["properties"]?.object?.keys.sorted() ?? []
            XCTAssertEqual(tool["input_schema"]?["required"]?.array?.compactMap(\.string), props)
        }
    }

    func testReadToolsRunAndAllResultsReturnInOneUserMessage() async throws {
        let thinking: JSONValue = ["type": "thinking", "thinking": "", "signature": "sig-abc"]
        let transport = ScriptedTransport([
            assistant([thinking, toolUse("t1", "list_pages", [:]),
                       toolUse("t2", "read_page", ["page": 1, "include_image": true])], stop: "tool_use"),
            assistant([["type": "text", "text": "Page 1 covers Coulomb's law."]], stop: "end_turn"),
        ])
        let host = FakeHost(notebook())
        let session = AgentSession(transport: transport, host: host)
        let reply = try await session.send("summarize")
        XCTAssertEqual(reply.toolCalls, ["list_pages", "read_page"])
        XCTAssertEqual(reply.text, "Page 1 covers Coulomb's law.")

        let second = try XCTUnwrap(transport.requests.last?["messages"]?.array)
        XCTAssertEqual(second.count, 3)
        // Assistant content (incl. thinking signature) is echoed back unchanged.
        XCTAssertEqual(second[1]["content"]?.array?.first, thinking)
        let results = try XCTUnwrap(second[2]["content"]?.array)
        XCTAssertEqual(results.compactMap { $0["tool_use_id"]?.string }, ["t1", "t2"])
        let listText = results[0]["content"]?.array?.first?["text"]?.string ?? ""
        XCTAssertTrue(listText.contains("2 page(s)"), listText)
        let read = try XCTUnwrap(results[1]["content"]?.array)
        XCTAssertTrue(read[0]["text"]?.string?.contains("Coulomb's law") == true)
        XCTAssertTrue(read[0]["text"]?.string?.contains("F = qE") == true)
        XCTAssertEqual(read[1]["type"]?.string, "image")
        XCTAssertEqual(read[1]["source"]?["media_type"]?.string, "image/png")
    }

    func testWritesRequireApprovalAndRejectionLeavesNotebookUntouched() async throws {
        let host = FakeHost(notebook(), decisions: [.approve, .reject(reason: "wrong spot")])
        let transport = ScriptedTransport([
            assistant([toolUse("a", "add_note", ["page": 1, "x": 600, "y": 100, "width": 300, "text": "Remember k = 8.99e9"])], stop: "tool_use"),
            assistant([toolUse("b", "add_highlight", ["page": 1, "x": 10, "y": 20, "width": 200, "height": 40, "color": "green"])], stop: "tool_use"),
            assistant([["type": "text", "text": "Done"]], stop: "end_turn"),
        ])
        let session = AgentSession(transport: transport, host: host)
        _ = try await session.send("annotate")

        XCTAssertEqual(host.asked.count, 2)
        let agentLayer = try XCTUnwrap(host.notebook.pages[0].agentLayerIndex)
        let added = host.notebook.pages[0].layers[agentLayer].elements
        XCTAssertEqual(added.count, 1)   // only the approved note
        guard case .text(let note) = added[0] else { return XCTFail() }
        XCTAssertEqual(note.text, "Remember k = 8.99e9")
        XCTAssertEqual(host.notebook.pages[0].layers[0].elements.count, 1)   // user layer untouched

        let msgs = try XCTUnwrap(transport.requests.last?["messages"]?.array)
        let rejected = msgs[4]["content"]?.array?.first?["content"]?.array?.first?["text"]?.string ?? ""
        XCTAssertTrue(rejected.contains("rejected") && rejected.contains("wrong spot"), rejected)
    }

    func testInvalidToolInputIsReportedAsErrorNotApplied() async throws {
        let host = FakeHost(notebook(), decisions: [.approve])
        let transport = ScriptedTransport([
            assistant([toolUse("a", "add_note", ["page": 9, "x": 1, "y": 1, "width": 10, "text": "x"]),
                       toolUse("b", "delete_everything", [:])], stop: "tool_use"),
            assistant([["type": "text", "text": "ok"]], stop: "end_turn"),
        ])
        _ = try await AgentSession(transport: transport, host: host).send("go")
        XCTAssertTrue(host.asked.isEmpty)
        let results = try XCTUnwrap(transport.requests.last?["messages"]?.array?.last?["content"]?.array)
        XCTAssertEqual(results.compactMap { $0["is_error"]?.bool }, [true, true])
    }

    func testRefusalAndTruncationCloseDanglingToolUses() async throws {
        let transport = ScriptedTransport([
            assistant([toolUse("x", "list_pages", [:])], stop: "max_tokens"),
            assistant([], stop: "refusal", extra: ["stop_details": ["type": "refusal", "category": "cyber", "explanation": "no"]]),
        ])
        let host = FakeHost(notebook())
        let session = AgentSession(transport: transport, host: host)
        let first = try await session.send("a")
        XCTAssertEqual(first.ending, .truncated)
        let history = await session.messages
        XCTAssertEqual(history.last?["content"]?.array?.first?["tool_use_id"]?.string, "x")
        let second = try await session.send("b")
        XCTAssertEqual(second.ending, .refused(category: "cyber", explanation: "no"))
        _ = host
    }

    func testClosedNotebookIsATypedError() async {
        let transport = ScriptedTransport([])
        let session = AgentSession(transport: transport, host: FakeHost(notebook()))   // host released immediately
        do { _ = try await session.send("x"); XCTFail("expected error") } catch {
            XCTAssertEqual(error as? AgentToolError, .notebookClosed)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testFallbackOnlyForModelsThatSupportIt() async throws {
        for (model, expectsFallback) in [("claude-sonnet-5-5", true), ("claude-haiku-5-5", false)] {
            let transport = ScriptedTransport([assistant([["type": "text", "text": "ok"]], stop: "end_turn")])
            let host = FakeHost(notebook())
            _ = try await AgentSession(transport: transport, host: host,
                                       configuration: AgentConfiguration(model: model, effort: "medium")).send("x")
            XCTAssertEqual(transport.requests.first?["fallbacks"] != nil, expectsFallback, model)
            XCTAssertEqual(transport.requests.first?["model"]?.string, model)
        }
    }

    func testHTTPErrorsKeepTheAPIMessage() {
        let body: JSONValue = ["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]]
        XCTAssertEqual(AnthropicHTTPTransport.error(status: 401, body: body, retryAfter: nil), .authentication("invalid x-api-key"))
        XCTAssertTrue(AgentAPIError.authentication("invalid x-api-key").description.contains("invalid x-api-key"))
        let notFound: JSONValue = ["error": ["message": "model: claude-sonnet-5.5"]]
        XCTAssertEqual(AnthropicHTTPTransport.error(status: 404, body: notFound, retryAfter: nil), .invalidRequest("model: claude-sonnet-5.5"))
        XCTAssertEqual(AnthropicHTTPTransport.error(status: 429, body: nil, retryAfter: "12"), .rateLimited(retryAfter: 12))
        XCTAssertNil(AnthropicHTTPTransport.error(status: 200, body: nil, retryAfter: nil))
    }

    func testJSONValueRoundTripsTypes() throws {
        let v: JSONValue = ["a": 1, "b": 1.5, "c": true, "d": .null, "e": ["x", 2]]
        XCTAssertEqual(try JSONValue.decode(try v.encoded()), v)
        XCTAssertEqual(try JSONValue.decode(Data("[true, 1]".utf8)), [true, 1])
    }
}
