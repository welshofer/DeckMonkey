import Foundation
import IWASnappy

/// Errors from splitting a decompressed `.iwa` stream into records.
public enum ArchiveStreamError: Error, Equatable, Sendable {
    case truncated(at: Int)
    case headerTooLong(at: Int)
}

/// One object record from an archive stream: its `TSP.ArchiveInfo` header followed by one
/// payload per `MessageInfo`. Untouched records re-emit byte-for-byte (invariant 2).
public struct ArchiveRecord: Equatable, Sendable {
    public var info: ArchiveInfo
    public var payloads: [Data]
    /// Whether this record was altered since it was read; the store uses it to re-derive headers.
    public var isDirty: Bool

    public init(info: ArchiveInfo, payloads: [Data], isDirty: Bool = false) {
        self.info = info
        self.payloads = payloads
        self.isDirty = isDirty
    }

    public var identifier: UInt64 { info.identifier }
    public var shouldMerge: Bool { info.shouldMerge }

    /// The record's serialized form: varint header length, header, payloads.
    public func encoded() -> [UInt8] {
        let header = info.encoded()
        var out = [UInt8]()
        out.reserveCapacity(header.count + payloads.reduce(0) { $0 + $1.count } + 8)
        Varint.write(UInt64(header.count), into: &out)
        out.append(contentsOf: header)
        for payload in payloads {
            out.append(contentsOf: payload)
        }
        return out
    }
}

public enum ArchiveStream {
    /// Splits a decompressed `.iwa` stream into records.
    public static func split(_ decompressed: Data) throws -> [ArchiveRecord] {
        let bytes = [UInt8](decompressed)
        var records = [ArchiveRecord]()
        var pos = 0
        while pos < bytes.count {
            let lengthStart = pos
            let headerLength: (value: UInt64, length: Int)
            do {
                headerLength = try Varint.read(bytes, at: pos)
            } catch {
                throw ArchiveStreamError.truncated(at: lengthStart)
            }
            pos += headerLength.length
            guard headerLength.value <= UInt64(Int.max) else { throw ArchiveStreamError.headerTooLong(at: lengthStart) }
            let n = Int(headerLength.value)
            guard pos + n <= bytes.count else { throw ArchiveStreamError.truncated(at: pos) }
            let info = try ArchiveInfo(bytes: Array(bytes[pos..<(pos + n)]))
            pos += n
            var payloads = [Data]()
            payloads.reserveCapacity(info.messageInfos.count)
            for messageInfo in info.messageInfos {
                let len = Int(messageInfo.length)
                guard pos + len <= bytes.count else { throw ArchiveStreamError.truncated(at: pos) }
                payloads.append(Data(bytes[pos..<(pos + len)]))
                pos += len
            }
            records.append(ArchiveRecord(info: info, payloads: payloads))
        }
        return records
    }

    /// Joins records back into a decompressed stream. `split` then `join` is the identity.
    public static func join(_ records: [ArchiveRecord]) -> Data {
        var out = [UInt8]()
        for record in records {
            out.append(contentsOf: record.encoded())
        }
        return Data(out)
    }
}
