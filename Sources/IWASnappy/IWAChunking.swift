import Foundation

/// Errors from Apple's IWA chunk framing.
public enum IWAChunkingError: Error, Equatable, Sendable {
    /// The chunk header's first byte was not 0x00.
    case invalidHeader(expected: UInt8, found: UInt8, at: Int)
    /// A chunk header or body ran past the end of the file.
    case truncated(at: Int)
    /// A chunk's compressed body did not fit a 24-bit length.
    case chunkTooLarge(Int)
}

/// Apple's framing for `.iwa` files: a sequence of chunks, each `0x00`, a 3-byte little-endian
/// compressed length, then a raw Snappy block. No stream identifier, no CRC32, no padding —
/// Apple dropped everything the standard Snappy framing format adds.
public enum IWAChunking {
    /// Compressed bytes allowed per chunk by the 24-bit length field.
    public static let maxChunkBody = (1 << 24) - 1

    /// Default uncompressed bytes per chunk when writing.
    public static let defaultChunkSize = 1 << 20

    /// Decompresses every chunk of an `.iwa` file and concatenates the results.
    public static func decompress(_ iwa: Data) throws -> Data {
        let src = [UInt8](iwa)
        var out = [UInt8]()
        out.reserveCapacity(src.count * 3)
        var pos = 0
        while pos < src.count {
            guard pos + 4 <= src.count else { throw IWAChunkingError.truncated(at: pos) }
            let headerType = src[pos]
            guard headerType == 0 else {
                throw IWAChunkingError.invalidHeader(expected: 0, found: headerType, at: pos)
            }
            let length = Int(src[pos + 1]) | (Int(src[pos + 2]) << 8) | (Int(src[pos + 3]) << 16)
            pos += 4
            guard pos + length <= src.count else { throw IWAChunkingError.truncated(at: pos) }
            let body = Array(src[pos..<(pos + length)])
            pos += length
            out.append(contentsOf: try Snappy.decompress(body))
        }
        return Data(out)
    }

    /// Splits `data` into chunks of at most `chunkSize` uncompressed bytes and frames each.
    public static func compress(_ data: Data, chunkSize: Int = defaultChunkSize) throws -> Data {
        let src = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(src.count / 2 + 64)
        var pos = 0
        repeat {
            let end = min(pos + chunkSize, src.count)
            let body = Snappy.compress(Array(src[pos..<end]))
            guard body.count <= maxChunkBody else { throw IWAChunkingError.chunkTooLarge(body.count) }
            out.append(0)
            out.append(UInt8(body.count & 0xFF))
            out.append(UInt8((body.count >> 8) & 0xFF))
            out.append(UInt8((body.count >> 16) & 0xFF))
            out.append(contentsOf: body)
            pos = end
        } while pos < src.count
        return Data(out)
    }

    /// The framed chunk bodies, still compressed, for tests and diagnostics.
    public static func chunkBodies(_ iwa: Data) throws -> [Data] {
        let src = [UInt8](iwa)
        var bodies = [Data]()
        var pos = 0
        while pos < src.count {
            guard pos + 4 <= src.count else { throw IWAChunkingError.truncated(at: pos) }
            guard src[pos] == 0 else {
                throw IWAChunkingError.invalidHeader(expected: 0, found: src[pos], at: pos)
            }
            let length = Int(src[pos + 1]) | (Int(src[pos + 2]) << 8) | (Int(src[pos + 3]) << 16)
            pos += 4
            guard pos + length <= src.count else { throw IWAChunkingError.truncated(at: pos) }
            bodies.append(Data(src[pos..<(pos + length)]))
            pos += length
        }
        return bodies
    }
}

extension IWAChunkingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidHeader(let expected, let found, let at):
            return "chunk header at byte \(at) starts with 0x\(String(found, radix: 16)), expected 0x\(String(expected, radix: 16))"
        case .truncated(let at): return "chunk at byte \(at) runs past the end of the file"
        case .chunkTooLarge(let size): return "chunk body of \(size) byte(s) does not fit a 24-bit length"
        }
    }
}
