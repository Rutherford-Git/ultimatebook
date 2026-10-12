import Foundation

/// Decoder for Apple `compression_lz4` framing used inside Goodnotes records:
/// `bv41 <u32 rawSize> <u32 encSize> <LZ4 block>` | `bv4- <u32 size> <raw>` ... `bv4$`.
/// Implemented directly so it behaves identically on iOS and Linux.
enum AppleLZ4 {
    enum Failure: Error, Equatable {
        case badMagic(offset: Int)
        case truncated
        case badOffset
        case sizeMismatch(expected: Int, got: Int)
    }

    /// Hard ceiling for one decoded blob; real stroke/text payloads are kilobytes.
    static let maxOutput = 64 << 20

    static func decode(_ input: Data) throws -> Data {
        var r = ByteReader(input)
        var out = [UInt8]()
        while true {
            guard let magic = r.take(4) else { throw Failure.truncated }
            switch String(decoding: magic, as: UTF8.self) {
            case "bv4$":
                return Data(out)
            case "bv41":
                guard let raw = r.fixed32(), let enc = r.fixed32(), let block = r.take(Int(enc)) else {
                    throw Failure.truncated
                }
                guard Int(raw) <= maxOutput - out.count else { throw Failure.truncated }
                let before = out.count
                try decodeBlock(Array(block), into: &out, outputSize: Int(raw))
                guard out.count - before == Int(raw) else {
                    throw Failure.sizeMismatch(expected: Int(raw), got: out.count - before)
                }
            case "bv4-":
                guard let n = r.fixed32(), let raw = r.take(Int(n)) else { throw Failure.truncated }
                out.append(contentsOf: raw)
            default:
                throw Failure.badMagic(offset: r.offset - 4 - input.startIndex)
            }
        }
    }

    /// Raw LZ4 block decompression. Matches may only reference bytes of the current block.
    static func decodeBlock(_ src: [UInt8], into out: inout [UInt8], outputSize: Int) throws {
        let blockStart = out.count
        let target = blockStart + outputSize
        var i = 0
        func readLength(_ base: Int) throws -> Int {
            var n = base
            guard base == 15 else { return n }
            while true {
                guard i < src.count else { throw Failure.truncated }
                let b = Int(src[i]); i += 1
                n += b
                if b != 255 { return n }
            }
        }
        while i < src.count {
            let token = Int(src[i]); i += 1
            let literals = try readLength(token >> 4)
            guard i + literals <= src.count, out.count + literals <= target else { throw Failure.truncated }
            out.append(contentsOf: src[i..<(i + literals)])
            i += literals
            if i >= src.count || out.count >= target { break }   // last sequence has no match
            guard i + 1 < src.count else { throw Failure.truncated }
            let distance = Int(src[i]) | Int(src[i + 1]) << 8
            i += 2
            let matchLength = try readLength(token & 15) + 4
            guard distance > 0, distance <= out.count - blockStart else { throw Failure.badOffset }
            guard out.count + matchLength <= target else { throw Failure.truncated }
            var from = out.count - distance
            for _ in 0..<matchLength {   // byte-by-byte: overlapping copies are legal in LZ4
                out.append(out[from]); from += 1
            }
        }
    }
}
