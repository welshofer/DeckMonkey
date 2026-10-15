import Foundation

/// Errors from the raw Snappy codec.
public enum SnappyError: Error, Equatable, Sendable {
    /// The stream ended inside an element.
    case truncated(at: Int)
    /// The uncompressed-length preamble was missing or unreadable.
    case invalidPreamble
    /// A copy element pointed before the start of the output, or had a zero offset.
    case invalidCopy(offset: Int, length: Int, at: Int)
    /// The stream decoded to a different length than its preamble declared.
    case lengthMismatch(declared: Int, actual: Int)
}

/// Raw Snappy (the block format, RFC-less: github.com/google/snappy/blob/main/format_description.txt).
///
/// No framing, no CRC — Apple's IWA chunking supplies its own 4-byte header (see `IWAChunking`).
/// Pure Swift by design: the reference C library made Swift build times unreasonable and offers
/// nothing the format needs. The decoder is exact; the encoder is a greedy single-hash matcher over
/// 64 KiB blocks that produces valid streams, not necessarily the shortest ones. Byte-identical
/// output to Keynote's own encoder is not a goal (docs/spec.md §12, Phase 0).
public enum Snappy {
    /// Uncompressed bytes per block in `compress`. Copy offsets never cross a block.
    public static let blockSize = 1 << 16

    // MARK: Decode

    public static func decompress(_ data: Data) throws -> Data {
        return Data(try decompress([UInt8](data)))
    }

    public static func decompress(_ src: [UInt8]) throws -> [UInt8] {
        guard !src.isEmpty else { throw SnappyError.invalidPreamble }
        var pos = 0
        let preamble: (value: UInt64, length: Int)
        do {
            preamble = try Varint.read(src, at: 0)
        } catch {
            throw SnappyError.invalidPreamble
        }
        pos += preamble.length
        guard preamble.value <= UInt64(Int.max) else { throw SnappyError.invalidPreamble }
        let expected = Int(preamble.value)
        var out = [UInt8]()
        out.reserveCapacity(min(expected, 1 << 26))

        while pos < src.count {
            let tag = src[pos]
            pos += 1
            switch tag & 0x03 {
            case 0:
                // Literal. Lengths 1...60 are inline; 61...64 (tag>>2 == 60...63) carry 1...4 extra LE bytes.
                var length = Int(tag >> 2)
                if length >= 60 {
                    let extra = length - 59
                    guard pos + extra <= src.count else { throw SnappyError.truncated(at: pos) }
                    var v = 0
                    for k in 0..<extra {
                        v |= Int(src[pos + k]) << (8 * k)
                    }
                    pos += extra
                    length = v
                }
                length += 1
                guard length <= src.count - pos else { throw SnappyError.truncated(at: pos) }
                out.append(contentsOf: src[pos..<(pos + length)])
                pos += length
            case 1:
                // Copy, 1-byte offset: length 4...11, offset 11 bits.
                let length = Int((tag >> 2) & 0x07) + 4
                guard pos < src.count else { throw SnappyError.truncated(at: pos) }
                let offset = (Int(tag >> 5) << 8) | Int(src[pos])
                pos += 1
                try copy(&out, offset: offset, length: length, at: pos)
            case 2:
                // Copy, 2-byte offset: length 1...64.
                let length = Int(tag >> 2) + 1
                guard pos + 2 <= src.count else { throw SnappyError.truncated(at: pos) }
                let offset = Int(src[pos]) | (Int(src[pos + 1]) << 8)
                pos += 2
                try copy(&out, offset: offset, length: length, at: pos)
            default:
                // Copy, 4-byte offset: length 1...64.
                let length = Int(tag >> 2) + 1
                guard pos + 4 <= src.count else { throw SnappyError.truncated(at: pos) }
                let offset = Int(src[pos]) | (Int(src[pos + 1]) << 8)
                    | (Int(src[pos + 2]) << 16) | (Int(src[pos + 3]) << 24)
                pos += 4
                try copy(&out, offset: offset, length: length, at: pos)
            }
        }
        guard out.count == expected else {
            throw SnappyError.lengthMismatch(declared: expected, actual: out.count)
        }
        return out
    }

    private static func copy(_ out: inout [UInt8], offset: Int, length: Int, at pos: Int) throws {
        guard offset > 0, offset <= out.count else {
            throw SnappyError.invalidCopy(offset: offset, length: length, at: pos)
        }
        var from = out.count - offset
        if offset >= length {
            out.append(contentsOf: out[from..<(from + length)])
        } else {
            // Overlapping copy: the run repeats itself, so copy byte by byte.
            for _ in 0..<length {
                out.append(out[from])
                from += 1
            }
        }
    }

    // MARK: Encode

    public static func compress(_ data: Data) -> Data {
        return Data(compress([UInt8](data)))
    }

    public static func compress(_ src: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(src.count / 2 + 32)
        Varint.write(UInt64(src.count), into: &out)
        var table = [Int32](repeating: -1, count: tableSize)
        var blockStart = 0
        while blockStart < src.count {
            let blockEnd = min(blockStart + blockSize, src.count)
            compressBlock(src, blockStart, blockEnd, &table, &out)
            blockStart = blockEnd
        }
        return out
    }

    private static let tableBits = 14
    private static let tableSize = 1 << tableBits

    private static func compressBlock(
        _ src: [UInt8], _ start: Int, _ end: Int, _ table: inout [Int32], _ out: inout [UInt8]
    ) {
        let length = end - start
        if length < 16 {
            emitLiteral(src, start, end, &out)
            return
        }
        for i in 0..<table.count {
            table[i] = -1
        }
        var literalStart = start
        var i = start
        let last = end - 4
        while i <= last {
            let word = load32(src, i)
            let h = hash(word)
            let candidate = Int(table[h])
            table[h] = Int32(i)
            if candidate >= start, load32(src, candidate) == word {
                var matchLength = 4
                while i + matchLength < end, src[candidate + matchLength] == src[i + matchLength] {
                    matchLength += 1
                }
                if literalStart < i {
                    emitLiteral(src, literalStart, i, &out)
                }
                emitCopy(offset: i - candidate, length: matchLength, into: &out)
                i += matchLength
                literalStart = i
            } else {
                i += 1
            }
        }
        if literalStart < end {
            emitLiteral(src, literalStart, end, &out)
        }
    }

    @inline(__always)
    private static func load32(_ src: [UInt8], _ i: Int) -> UInt32 {
        return UInt32(src[i]) | (UInt32(src[i + 1]) << 8) | (UInt32(src[i + 2]) << 16) | (UInt32(src[i + 3]) << 24)
    }

    @inline(__always)
    private static func hash(_ word: UInt32) -> Int {
        return Int((word &* 0x1E35_A7BD) >> UInt32(32 - tableBits))
    }

    private static func emitLiteral(_ src: [UInt8], _ start: Int, _ end: Int, _ out: inout [UInt8]) {
        var pos = start
        while pos < end {
            let n = min(end - pos, 1 << 24)
            let n1 = n - 1
            if n1 < 60 {
                out.append(UInt8(n1 << 2))
            } else if n1 < (1 << 8) {
                out.append(60 << 2)
                out.append(UInt8(n1))
            } else if n1 < (1 << 16) {
                out.append(61 << 2)
                out.append(UInt8(n1 & 0xFF))
                out.append(UInt8((n1 >> 8) & 0xFF))
            } else {
                out.append(62 << 2)
                out.append(UInt8(n1 & 0xFF))
                out.append(UInt8((n1 >> 8) & 0xFF))
                out.append(UInt8((n1 >> 16) & 0xFF))
            }
            out.append(contentsOf: src[pos..<(pos + n)])
            pos += n
        }
    }

    /// Offsets are always < 65536 here because matches never cross a 64 KiB block.
    private static func emitCopy(offset: Int, length: Int, into out: inout [UInt8]) {
        var remaining = length
        while remaining > 64 {
            emitCopy2(offset: offset, length: 60, into: &out)
            remaining -= 60
        }
        if remaining >= 4, remaining <= 11, offset < 2048 {
            out.append(UInt8(((remaining - 4) << 2) | ((offset >> 8) << 5) | 1))
            out.append(UInt8(offset & 0xFF))
        } else {
            emitCopy2(offset: offset, length: remaining, into: &out)
        }
    }

    private static func emitCopy2(offset: Int, length: Int, into out: inout [UInt8]) {
        out.append(UInt8(((length - 1) << 2) | 2))
        out.append(UInt8(offset & 0xFF))
        out.append(UInt8((offset >> 8) & 0xFF))
    }
}

extension SnappyError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .truncated(let at): return "snappy: stream ends inside an element at byte \(at)"
        case .invalidPreamble: return "snappy: missing or unreadable length preamble"
        case .invalidCopy(let offset, let length, let at):
            return "snappy: copy of \(length) byte(s) at offset \(offset) reaches before the output start (element at byte \(at))"
        case .lengthMismatch(let declared, let actual):
            return "snappy: decoded \(actual) byte(s), preamble declared \(declared)"
        }
    }
}
