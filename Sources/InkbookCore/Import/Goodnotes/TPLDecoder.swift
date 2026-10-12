import Foundation

/// Decoder for Goodnotes' self-describing `tpl` payload (found inside stroke records):
/// `"tpl\0" <u32 totalSize> <ASCII signature> \0 <little-endian values>`.
/// Signature grammar: `v` u16, `u` 32-bit word, `f` f32, `A(x)` u32 count + items, `S(...)` struct.
enum TPL {
    indirect enum Node: Equatable {
        case u16, word, f32
        case array(Node)
        case record([Node])
    }

    indirect enum Value: Equatable {
        case u16(UInt16)
        case word(UInt32)
        case array([Value])
        case record([Value])

        var asFloat: Double? {
            if case .word(let w) = self { return Double(Float(bitPattern: w)) }
            return nil
        }

        var asInt: Int? {
            switch self {
            case .u16(let v): Int(v)
            case .word(let v): Int(v)
            default: nil
            }
        }

        var items: [Value] {
            switch self {
            case .array(let v), .record(let v): v
            default: []
            }
        }
    }

    enum Failure: Error, Equatable {
        case badHeader, badSignature(String), truncated, trailingBytes(Int)
    }

    struct Document {
        let signature: String
        let values: [Value]
    }

    /// Upper bound on any array count, so a corrupt count cannot trigger huge allocations
    /// (each element is at least 2 bytes, so count can never exceed the payload size).
    static func decode(_ data: Data) throws -> Document {
        var r = ByteReader(data)
        guard let magic = r.take(4), magic == Data("tpl\0".utf8), let total = r.fixed32() else {
            throw Failure.badHeader
        }
        var sigBytes = [UInt8]()
        while let b = r.byte(), b != 0 { sigBytes.append(b) }
        let signature = String(decoding: sigBytes, as: UTF8.self)
        let nodes = try parseSignature(signature)
        var values: [Value] = []
        for node in nodes { values.append(try read(node, &r)) }
        guard r.isAtEnd else { throw Failure.trailingBytes(r.remaining) }
        guard Int(total) == data.count else { throw Failure.badHeader }
        return Document(signature: signature, values: values)
    }

    static func parseSignature(_ s: String) throws -> [Node] {
        let chars = Array(s)
        var i = 0
        func parseList(until terminator: Character?) throws -> [Node] {
            var out: [Node] = []
            while i < chars.count {
                let c = chars[i]
                if let t = terminator, c == t { i += 1; return out }
                i += 1
                switch c {
                case "v": out.append(.u16)
                case "u": out.append(.word)
                case "f": out.append(.f32)
                case "A", "S":
                    guard i < chars.count, chars[i] == "(" else { throw Failure.badSignature(s) }
                    i += 1
                    let inner = try parseList(until: ")")
                    if c == "A" {
                        guard inner.count == 1 else { throw Failure.badSignature(s) }
                        out.append(.array(inner[0]))
                    } else {
                        out.append(.record(inner))
                    }
                default: throw Failure.badSignature(s)
                }
            }
            if terminator != nil { throw Failure.badSignature(s) }
            return out
        }
        return try parseList(until: nil)
    }

    private static func read(_ node: Node, _ r: inout ByteReader) throws -> Value {
        switch node {
        case .u16:
            guard let v = r.uint16() else { throw Failure.truncated }
            return .u16(v)
        case .word, .f32:
            guard let v = r.fixed32() else { throw Failure.truncated }
            return .word(v)
        case .record(let fields):
            return .record(try fields.map { try read($0, &r) })
        case .array(let element):
            guard let count = r.fixed32(), Int(count) <= r.remaining else { throw Failure.truncated }
            var items: [Value] = []
            items.reserveCapacity(Int(count))
            for _ in 0..<count { items.append(try read(element, &r)) }
            return .array(items)
        }
    }
}
