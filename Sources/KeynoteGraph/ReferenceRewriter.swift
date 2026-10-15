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

    public enum Failure: Error, Equatable, Sendable { case malformed(at: Int), groups, tooDeep }

    /// Deeper nesting than any Keynote payload uses is refused, so hostile input cannot exhaust the
    /// stack (the deepest corpus payload is far shallower).
    public static let maximumDepth = 64

    /// A family of UUIDs that moves together: every UUID with `old`'s upper half and a lower half
    /// within `span` above `old`'s becomes `new` plus the same offset (a table's formula owners).
    public struct UUIDFamily: Hashable, Sendable {
        public var old: UUIDValue, new: UUIDValue, span: UInt64
        public init(old: UUIDValue, new: UUIDValue, span: UInt64) { self.old = old; self.new = new; self.span = span }
    }

    public let index: FieldIndex
    public var identifiers: [UInt64: UInt64]
    public var uuids: [UUIDValue: UUIDValue]
    public var families: [UUIDFamily]
    /// The calculation engine's internal owner identifiers (uint32 fields of `TSCE.*` messages
    /// named `owner_id`, `to_owner_id`, `internal_owner_id`, `internal_formula_owner_id`,
    /// `internal_owner_id_for_edge`), old → new.
    public var ownerIDs: [UInt64: UInt64]
    let ownerIDFields: [String: Set<Int>]

    public init(index: FieldIndex, identifiers: [UInt64: UInt64], uuids: [UUIDValue: UUIDValue] = [:], families: [UUIDFamily] = [],
                ownerIDs: [UInt64: UInt64] = [:]) {
        self.index = index
        self.identifiers = identifiers
        self.uuids = uuids
        self.families = families
        self.ownerIDs = ownerIDs
        var fields = [String: Set<Int>]()
        if !ownerIDs.isEmpty {
            for (message, numbers) in index.uint32Fields where message.hasPrefix("TSCE.") {
                for (number, name) in numbers where Self.ownerIDFieldNames.contains(name) { fields[message, default: []].insert(number) }
            }
        }
        ownerIDFields = fields
    }

    static let ownerIDFieldNames: Set<String> = ["owner_id", "to_owner_id", "internal_owner_id", "internal_formula_owner_id", "internal_owner_id_for_edge"]

    /// The new UUID for `u`, nil when it does not move.
    public func mapped(_ u: UUIDValue) -> UUIDValue? {
        if let exact = uuids[u] { return exact }
        for f in families where u.upper == f.old.upper && u.lower >= f.old.lower && u.lower - f.old.lower < f.span {
            return UUIDValue(lower: f.new.lower &+ (u.lower - f.old.lower), upper: f.new.upper)
        }
        return nil
    }

    /// The payload of a `message` (full proto name) with references and UUIDs rewritten.
    public func rewrite(_ payload: Data, message: String) throws -> Data {
        let bytes = [UInt8](payload)
        let out = try rewrite(bytes[...], message: message, depth: 0)
        return out.map { Data($0) } ?? payload
    }

    /// Nil when nothing changed (the caller keeps the original bytes).
    func rewrite(_ b: ArraySlice<UInt8>, message: String, depth: Int) throws -> [UInt8]? {
        guard depth <= Self.maximumDepth else { throw Failure.tooDeep }
        if message == "TSP.Reference" { return rewriteReference(b) }
        if message == "TSP.UUID" { return rewriteUUID(b) }
        if message == "TSP.CFUUIDArchive" { return rewriteCFUUID(b) }
        var out = [UInt8](), changed = false, i = b.startIndex
        out.reserveCapacity(b.count)
        while i < b.endIndex {
            let start = i
            guard let (tag, afterTag) = Self.varint(b, i) else { throw Failure.malformed(at: i - b.startIndex) }
            let number = Int(tag >> 3), wire = tag & 7
            switch wire {
            case 0:
                guard let (value, next) = Self.varint(b, afterTag) else { throw Failure.malformed(at: afterTag - b.startIndex) }
                if ownerIDFields[message]?.contains(number) == true, let new = ownerIDs[value] {
                    out += b[start..<afterTag]; Self.appendVarint(new, to: &out); changed = true
                } else {
                    out += b[start..<next]
                }
                i = next
            case 1:
                guard afterTag + 8 <= b.endIndex else { throw Failure.malformed(at: afterTag - b.startIndex) }
                out += b[start..<(afterTag + 8)]; i = afterTag + 8
            case 5:
                guard afterTag + 4 <= b.endIndex else { throw Failure.malformed(at: afterTag - b.startIndex) }
                out += b[start..<(afterTag + 4)]; i = afterTag + 4
            case 2:
                // Compare as UInt64 before converting: a hostile length must not trap.
                guard let (length, bodyStart) = Self.varint(b, afterTag), length <= UInt64(b.endIndex - bodyStart) else {
                    throw Failure.malformed(at: afterTag - b.startIndex)
                }
                let body = b[bodyStart..<(bodyStart + Int(length))]
                if ownerIDFields[message]?.contains(number) == true {
                    // A packed repeated owner identifier.
                    var packed = [UInt8](), j = body.startIndex, moved = false
                    while j < body.endIndex {
                        guard let (value, next) = Self.varint(body, j) else { throw Failure.malformed(at: j - b.startIndex) }
                        if let new = ownerIDs[value] { Self.appendVarint(new, to: &packed); moved = true } else { packed += body[j..<next] }
                        j = next
                    }
                    if moved {
                        out += b[start..<afterTag]; Self.appendVarint(UInt64(packed.count), to: &out); out += packed; changed = true
                    } else {
                        out += b[start..<body.endIndex]
                    }
                } else if let sub = index.subMessage(of: message, field: number), let rewritten = try rewrite(body, message: sub, depth: depth + 1) {
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
        guard let lower, let upper, let new = mapped(UUIDValue(lower: lower, upper: upper)) else { return nil }
        var out: [UInt8] = [0x08]
        Self.appendVarint(new.lower, to: &out)
        out.append(0x10)
        Self.appendVarint(new.upper, to: &out)
        return out
    }

    /// `TSP.CFUUIDArchive`: four 32-bit words (w0 | w1 << 32 is the lower half, w2 | w3 << 32 the
    /// upper) or sixteen bytes (the lower half little-endian, then the upper). Re-encoded in the
    /// form it came in.
    func rewriteCFUUID(_ b: ArraySlice<UInt8>) -> [UInt8]? {
        var words = [UInt64](repeating: 0, count: 4), bytes: [UInt8]?, i = b.startIndex
        while i < b.endIndex, let (tag, afterTag) = Self.varint(b, i) {
            let number = Int(tag >> 3)
            if tag & 7 == 0, (2...5).contains(number), let (v, next) = Self.varint(b, afterTag) {
                words[number - 2] = v & 0xFFFF_FFFF
                i = next
            } else if tag == 0x0A, let (n, start) = Self.varint(b, afterTag), n == 16, start + 16 <= b.endIndex {
                bytes = Array(b[start..<(start + 16)])
                i = start + 16
            } else if let end = Self.fieldEnd(b, tag: tag, afterTag: afterTag) {
                i = end
            } else {
                return nil
            }
        }
        func le(_ a: [UInt8], _ r: Range<Int>) -> UInt64 { r.reversed().reduce(0) { $0 << 8 | UInt64(a[$1]) } }
        let old = bytes.map { UUIDValue(lower: le($0, 0..<8), upper: le($0, 8..<16)) }
            ?? UUIDValue(lower: words[1] << 32 | words[0], upper: words[3] << 32 | words[2])
        guard let new = mapped(old) else { return nil }
        var out = [UInt8]()
        if bytes != nil {
            out = [0x0A, 16]
            for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: new.lower >> (8 * k))) }
            for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: new.upper >> (8 * k))) }
        } else {
            for (number, w) in [(2, new.lower), (3, new.lower >> 32), (4, new.upper), (5, new.upper >> 32)] {
                out.append(UInt8(number << 3))
                Self.appendVarint(w & 0xFFFF_FFFF, to: &out)
            }
        }
        return out
    }

    static func fieldEnd(_ b: ArraySlice<UInt8>, tag: UInt64, afterTag: Int) -> Int? {
        switch tag & 7 {
        case 0: return varint(b, afterTag)?.1
        case 1: return afterTag + 8 <= b.endIndex ? afterTag + 8 : nil
        case 5: return afterTag + 4 <= b.endIndex ? afterTag + 4 : nil
        case 2:
            guard let (n, start) = varint(b, afterTag), n <= UInt64(b.endIndex - start) else { return nil }
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
