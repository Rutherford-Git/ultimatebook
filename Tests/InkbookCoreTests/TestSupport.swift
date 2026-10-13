import Foundation
@testable import InkbookCore

/// Minimal protobuf encoder for building synthetic Goodnotes files in tests.
enum PB {
    static func varint(_ v: UInt64) -> Data {
        var v = v, out = Data()
        repeat {
            var b = UInt8(v & 0x7F); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    static func key(_ field: Int, _ wire: UInt64) -> Data { varint(UInt64(field) << 3 | wire) }
    static func uint(_ field: Int, _ v: UInt64) -> Data { key(field, 0) + varint(v) }
    static func bytes(_ field: Int, _ d: Data) -> Data { key(field, 2) + varint(UInt64(d.count)) + d }
    static func string(_ field: Int, _ s: String) -> Data { bytes(field, Data(s.utf8)) }
    static func float(_ field: Int, _ f: Float) -> Data { key(field, 5) + le32(f.bitPattern) }
    static func point(_ field: Int, _ x: Float, _ y: Float) -> Data { bytes(field, float(1, x) + float(2, y)) }
    static func delimited(_ messages: [Data]) -> Data { messages.reduce(Data()) { $0 + varint(UInt64($1.count)) + $1 } }

    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Apple LZ4 framing using an uncompressed `bv4-` chunk.
    static func appleRaw(_ d: Data) -> Data { Data("bv4-".utf8) + le32(UInt32(d.count)) + d + Data("bv4$".utf8) }

    /// `tpl` payload for the main Goodnotes stroke signature.
    static func strokeTPL(width: Float, start: (Float, Float), segments: [(Float, Float, Float, Float)]) -> Data {
        let sig = "vuA(v)A(S(uu))A(S(uuuu))vA(f)"
        var body = le16(2) + le32(width.bitPattern)
        body += le32(UInt32(segments.count + 1)) + le16(0)
        for _ in segments { body += le16(1) }
        body += le32(1) + le32(start.0.bitPattern) + le32(start.1.bitPattern)
        body += le32(UInt32(segments.count))
        for s in segments { for f in [s.0, s.1, s.2, s.3] { body += le32(f.bitPattern) } }
        body += le16(1) + le32(0)
        let header = Data("tpl\0".utf8)
        let sigData = Data(sig.utf8) + Data([0])
        let total = UInt32(header.count + 4 + sigData.count + body.count)
        return header + le32(total) + sigData + body
    }
}

/// In-memory `.goodnotes` contents.
struct MemorySource: GoodnotesSource {
    var files: [String: Data]
    func data(at path: String) -> Data? { files[path] }
}

/// Scripted Messages API responses; records every request body.
final class ScriptedTransport: MessagesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [JSONValue]
    private(set) var requests: [JSONValue] = []

    init(_ responses: [JSONValue]) { self.responses = responses }

    func send(_ body: JSONValue) async throws -> JSONValue { try record(body) }

    private func record(_ body: JSONValue) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        // Snapshot the body as sent (the session mutates its history afterwards).
        requests.append(try JSONValue.decode(try body.encoded()))
        guard !responses.isEmpty else { throw AgentAPIError.malformedResponse }
        return responses.removeFirst()
    }
}

final class FakeHost: AgentNotebookHost, @unchecked Sendable {
    var notebook: Notebook
    var decisions: [ApprovalDecision]
    private(set) var asked: [AgentProposal] = []
    var png: Data? = Data([0x89, 0x50, 0x4E, 0x47])
    var diagnostics: String?

    init(_ notebook: Notebook, decisions: [ApprovalDecision] = []) {
        self.notebook = notebook; self.decisions = decisions
    }

    func snapshot() async -> Notebook { notebook }
    func apply(_ proposal: AgentProposal) async throws { try proposal.apply(to: &notebook) }
    func renderPage(_ index: Int, maxPixels: Int) async -> Data? { png }
    func requestApproval(_ proposal: AgentProposal) async -> ApprovalDecision {
        asked.append(proposal)
        return decisions.isEmpty ? .reject(reason: nil) : decisions.removeFirst()
    }
    func diagnosticsReport() async -> String? { diagnostics }
}

func assistant(_ content: [JSONValue], stop: String, extra: [String: JSONValue] = [:]) -> JSONValue {
    var o: [String: JSONValue] = ["type": "message", "role": "assistant", "content": .array(content), "stop_reason": .string(stop)]
    for (k, v) in extra { o[k] = v }
    return .object(o)
}

func toolUse(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
    ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]
}
