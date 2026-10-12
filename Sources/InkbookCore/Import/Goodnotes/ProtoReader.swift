import Foundation

/// Schema-less protobuf wire-format reader. Goodnotes ships no `.proto` files, so the
/// importer addresses fields by number (see docs/GOODNOTES_FORMAT.md).
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    struct Field {
        let number: Int
        let value: Value
    }

    let fields: [Field]

    /// Parses one message; returns nil if the bytes are not a well-formed message.
    init?(_ data: Data) {
        var out: [Field] = []
        var r = ByteReader(data)
        while !r.isAtEnd {
            guard let key = r.varint() else { return nil }
            let number = Int(key >> 3)
            guard number > 0 else { return nil }
            switch key & 7 {
            case 0: guard let v = r.varint() else { return nil }; out.append(Field(number: number, value: .varint(v)))
            case 1: guard let v = r.fixed64() else { return nil }; out.append(Field(number: number, value: .fixed64(v)))
            case 5: guard let v = r.fixed32() else { return nil }; out.append(Field(number: number, value: .fixed32(v)))
            case 2:
                guard let n = r.varint(), let v = r.take(Int(n)) else { return nil }
                out.append(Field(number: number, value: .bytes(v)))
            default: return nil
            }
        }
        fields = out
    }

    /// First field with this number.
    func first(_ number: Int) -> Value? { fields.first { $0.number == number }?.value }
    func all(_ number: Int) -> [Value] { fields.filter { $0.number == number }.map(\.value) }

    func bytes(_ number: Int) -> Data? {
        if case .bytes(let d)? = first(number) { return d }
        return nil
    }

    func string(_ number: Int) -> String? { bytes(number).flatMap { String(data: $0, encoding: .utf8) } }
    func message(_ number: Int) -> ProtoMessage? { bytes(number).flatMap(ProtoMessage.init) }

    func uint(_ number: Int) -> UInt64? {
        if case .varint(let v)? = first(number) { return v }
        return nil
    }

    func float(_ number: Int) -> Double? {
        switch first(number) {
        case .fixed32(let v)?: Double(Float(bitPattern: v))
        case .fixed64(let v)?: Double(bitPattern: v)
        default: nil
        }
    }

    /// Splits a stream of varint-length-prefixed messages (Goodnotes `*.pb` and `notes/*`).
    static func delimitedStream(_ data: Data) -> [Data] {
        var r = ByteReader(data)
        var out: [Data] = []
        while !r.isAtEnd {
            guard let n = r.varint(), let m = r.take(Int(n)) else { break }
            out.append(m)
        }
        return out
    }
}

/// Bounds-checked little-endian cursor over `Data` (works on slices with non-zero startIndex).
struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) { self.data = data; offset = data.startIndex }

    var isAtEnd: Bool { offset >= data.endIndex }
    var remaining: Int { data.endIndex - offset }

    mutating func byte() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func take(_ n: Int) -> Data? {
        guard n >= 0, n <= remaining else { return nil }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard let b = byte() else { return nil }
            result |= UInt64(b & 0x7F) << shift
            if b < 0x80 { return result }
            shift += 7
        }
        return nil
    }

    mutating func uint16() -> UInt16? {
        guard let d = take(2) else { return nil }
        return UInt16(d[d.startIndex]) | UInt16(d[d.startIndex + 1]) << 8
    }

    mutating func fixed32() -> UInt32? {
        guard let d = take(4) else { return nil }
        return d.reduce(into: (UInt32(0), UInt32(0))) { acc, b in
            acc.0 |= UInt32(b) << acc.1; acc.1 += 8
        }.0
    }

    mutating func fixed64() -> UInt64? {
        guard let lo = fixed32(), let hi = fixed32() else { return nil }
        return UInt64(lo) | UInt64(hi) << 32
    }
}
