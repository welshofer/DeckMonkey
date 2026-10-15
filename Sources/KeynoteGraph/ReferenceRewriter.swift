import Foundation
import IWASchema

/// Rewrites object references and object UUIDs inside a serialized payload, at the wire level,
/// guided by the schema's field index: a `TSP.Reference` whose identifier is in `identifiers` gets
/// the new one, a `TSP.UUID` in `uuids` gets the new UUID, and every other byte — unknown fields,
/// field order, encodings — is copied as it was. A sub-message is re-encoded (a new length prefix)
/// only when something inside it changed. This is the "same traversal, with an identifier map
/// instead of a collector" of docs/spec.md §9, used by slide clone.
public struct ReferenceRewriter: Sendable {
    public struct UUIDValue: Hashable, Sendable {
        public var lower: UInt64, upper: UInt64
        public init(lower: UInt64, upper: UInt64) { self.lower = lower; self.upper = upper }
    }

    public enum Failure: Error, Equatable, Sendable { case malformed(at: Int), groups }

    public let index: FieldIndex
    public var identifiers: [UInt64: UInt64]
    public var uuids: [UUIDValue: UUIDValue]

    public init(index: FieldIndex, identifiers: [UInt64: UInt64], uuids: [UUIDValue: UUIDValue] = [:]) {
        self.index = index
        self.identifiers = identifiers
        self.uuids = uuids
    }

    /// The payload of a `message` (full proto name) with references and UUIDs rewritten.
    public func rewrite(_ payload: Data, message: String) throws -> Data {
        let bytes = [UInt8](payload)
        let out = try rewrite(bytes[...], message: message)
        return out.map { Data($0) } ?? payload
    }

    /// Nil when nothing changed (the caller keeps the original bytes).
    func rewrite(_ b: ArraySlice<UInt8>, message: String) throws -> [UInt8]? {
        if message == "TSP.Reference" { return rewriteReference(b) }
        if message == "TSP.UUID" { return rewriteUUID(b) }
        var out = [UInt8](), changed = false, i = b.startIndex
        out.reserveCapacity(b.count)
        while i < b.endIndex {
            let start = i
            guard let (tag, afterTag) = Self.varint(b, i) else { throw Failure.malformed(at: i - b.startIndex) }
            let number = Int(tag >> 3), wire = tag & 7
            switch wire {
            case 0:
                guard let (_, next) = Self.varint(b, afterTag) else { throw Failure.malformed(at: afterTag - b.startIndex) }
                out += b[start..<next]; i = next
            case 1:
                guard afterTag + 8 <= b.endIndex else { throw Failure.malformed(at: afterTag - b.startIndex) }
                out += b[start..<(afterTag + 8)]; i = afterTag + 8
            case 5:
                guard afterTag + 4 <= b.endIndex else { throw Failure.malformed(at: afterTag - b.startIndex) }
                out += b[start..<(afterTag + 4)]; i = afterTag + 4
            case 2:
                guard let (length, bodyStart) = Self.varint(b, afterTag), bodyStart + Int(length) <= b.endIndex else {
                    throw Failure.malformed(at: afterTag - b.startIndex)
                }
                let body = b[bodyStart..<(bodyStart + Int(length))]
                if let sub = index.subMessage(of: message, field: number), let rewritten = try rewrite(body, message: sub) {
                    out += b[start..<afterTag]
                    Self.appendVarint(UInt64(rewritten.count), to: &out)
                    out += rewritten
                    changed = true
                } else {
                    out += b[start..<body.endIndex]
                }
                i = body.endIndex
            default:
                throw Failure.groups
            }
        }
        return changed ? out : nil
    }

    func rewriteReference(_ b: ArraySlice<UInt8>) -> [UInt8]? {
        var out = [UInt8](), changed = false, i = b.startIndex
        while i < b.endIndex, let (tag, afterTag) = Self.varint(b, i) {
            if tag == 0x08, let (id, next) = Self.varint(b, afterTag), let new = identifiers[id] {
                out.append(0x08); Self.appendVarint(new, to: &out); changed = true; i = next
            } else if let end = Self.fieldEnd(b, tag: tag, afterTag: afterTag) {
                out += b[i..<end]; i = end
            } else {
                return nil
            }
        }
        return changed ? out : nil
    }

    func rewriteUUID(_ b: ArraySlice<UInt8>) -> [UInt8]? {
        var lower: UInt64?, upper: UInt64?, i = b.startIndex
        while i < b.endIndex, let (tag, afterTag) = Self.varint(b, i) {
            if (tag == 0x08 || tag == 0x10), let (v, next) = Self.varint(b, afterTag) {
                if tag == 0x08 { lower = v } else { upper = v }
                i = next
            } else if let end = Self.fieldEnd(b, tag: tag, afterTag: afterTag) {
                i = end
            } else {
                return nil
            }
        }
        guard let lower, let upper, let new = uuids[UUIDValue(lower: lower, upper: upper)] else { return nil }
        var out: [UInt8] = [0x08]
        Self.appendVarint(new.lower, to: &out)
        out.append(0x10)
        Self.appendVarint(new.upper, to: &out)
        return out
    }

    static func fieldEnd(_ b: ArraySlice<UInt8>, tag: UInt64, afterTag: Int) -> Int? {
        switch tag & 7 {
        case 0: return varint(b, afterTag)?.1
        case 1: return afterTag + 8 <= b.endIndex ? afterTag + 8 : nil
        case 5: return afterTag + 4 <= b.endIndex ? afterTag + 4 : nil
        case 2:
            guard let (n, start) = varint(b, afterTag), start + Int(n) <= b.endIndex else { return nil }
            return start + Int(n)
        default: return nil
        }
    }

    static func varint(_ b: ArraySlice<UInt8>, _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0, shift: UInt64 = 0, i = start
        while i < b.endIndex, shift < 64 {
            let byte = b[i]
            result |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte < 0x80 { return (result, i) }
            shift += 7
        }
        return nil
    }

    static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        out.append(UInt8(v))
    }
}
