import Foundation

/// Errors from reading protobuf-style base-128 varints.
public enum VarintError: Error, Equatable, Sendable {
    /// The buffer ended before the varint's terminating byte.
    case truncated(at: Int)
    /// More than 10 bytes without a terminator.
    case overlong(at: Int)
}

/// Base-128 varints as used by Protocol Buffers, Snappy preambles, and IWA archive length prefixes.
public enum Varint {
    /// Reads a varint starting at `pos`. Returns the value and the number of bytes consumed.
    public static func read(_ bytes: [UInt8], at pos: Int) throws -> (value: UInt64, length: Int) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = pos
        while true {
            guard i < bytes.count else { throw VarintError.truncated(at: pos) }
            guard i - pos < 10 else { throw VarintError.overlong(at: pos) }
            let b = bytes[i]
            result |= UInt64(b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { break }
            shift += 7
        }
        return (result, i - pos)
    }

    /// Appends the minimal varint encoding of `value`.
    public static func write(_ value: UInt64, into out: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    /// Number of bytes `write` would append for `value`.
    public static func encodedLength(_ value: UInt64) -> Int {
        var v = value
        var n = 1
        while v >= 0x80 {
            v >>= 7
            n += 1
        }
        return n
    }
}
