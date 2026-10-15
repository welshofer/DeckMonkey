import Foundation
import IWASchema
import SwiftProtobuf

/// The references a payload actually contains, found by decoding it with the pinned schema and
/// walking every field, extension and map value (invariant 4: reference lists are derived, never
/// typed). `objects` holds every `TSP.Reference.identifier`, `data` every
/// `TSP.DataReference.identifier`, in traversal order with repeats, so callers decide how the
/// stored `MessageInfo` lists relate (AT-07 and AT-08 measure that on the corpus).
public struct DerivedReferences: Equatable, Sendable {
    public var objects: [UInt64] = []
    public var data: [UInt64] = []
    /// Where each entry of `objects` was found: `<message full name>.<field number>`.
    public var objectFields: [String] = []
    /// True when the decoded payload kept unknown fields: references inside them cannot be seen.
    public var hasUnknownFields = false
}

public enum ReferenceDerivation {
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The type has no message in the pinned schema (deprecated, or a newer Keynote's).
        case noMessage(type: UInt32)
        case undecodable(type: UInt32, detail: String)

        public var description: String {
            switch self {
            case .noMessage(let type): return "type \(type) has no message in schema \(Schema.keynoteVersion)"
            case .undecodable(let type, let detail): return "type \(type) payload does not decode: \(detail)"
            }
        }
    }

    /// Decodes `payload` as `type` and collects its references. Decoding is partial: a reader
    /// must not refuse a payload over a missing `required` field it does not need.
    public static func derive(type: UInt32, payload: Data) throws(Failure) -> DerivedReferences {
        guard let messageType = Schema.messageType(for: type) else { throw .noMessage(type: type) }
        let message: any SwiftProtobuf.Message
        do {
            message = try messageType.init(serializedBytes: payload, extensions: Schema.extensions, partial: true, options: BinaryDecodingOptions())
        } catch {
            throw .undecodable(type: type, detail: "\(error)")
        }
        var collector = ReferenceCollector(root: messageType.protoMessageName)
        do {
            try message.traverse(visitor: &collector)
        } catch {
            throw .undecodable(type: type, detail: "traverse: \(error)")
        }
        return collector.found
    }
}

/// Walks a decoded message. `TSP.Reference` and `TSP.DataReference` are leaves: their identifier
/// is recorded and they are not descended into.
struct ReferenceCollector: Visitor {
    var found = DerivedReferences()
    var enclosing: [String] = []

    init(root: String = "") { enclosing = [root] }

    mutating func visitSingularMessageField<M: Message>(value: M, fieldNumber: Int) throws {
        if let reference = value as? TSP_Reference {
            found.objects.append(reference.identifier)
            found.objectFields.append("\(enclosing.last ?? "").\(fieldNumber)")
        } else if let reference = value as? TSP_DataReference {
            found.data.append(reference.identifier)
        } else {
            enclosing.append(M.protoMessageName)
            defer { enclosing.removeLast() }
            try value.traverse(visitor: &self)
        }
    }

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value: _ProtobufMessageMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {
        for (_, v) in value { try visitSingularMessageField(value: v, fieldNumber: fieldNumber) }
    }

    mutating func visitMapField<KeyType, ValueType: MapValueType>(
        fieldType: _ProtobufMap<KeyType, ValueType>.Type,
        value: _ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {}

    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufEnumMap<KeyType, ValueType>.Type,
        value: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws where ValueType.RawValue == Int {}

    mutating func visitUnknown(bytes: Data) throws {
        if !bytes.isEmpty { found.hasUnknownFields = true }
    }

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {}
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {}
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {}
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {}
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {}
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {}
    mutating func visitSingularEnumField<E: Enum>(value: E, fieldNumber: Int) throws {}
}

// MARK: - Strong references (invariant 4)

extension ReferenceDerivation {
    public enum ListingFailure: Error, Equatable, Sendable, CustomStringConvertible {
        /// A reference field the strength table has never seen: refuse rather than guess.
        case unclassifiedField(String)

        public var description: String {
            switch self {
            case .unclassifiedField(let field):
                return "reference field \(field) has no strength in reference-strength-\(Schema.keynoteVersion).json; rerun `make reference-strength`"
            }
        }
    }

    /// The `object_references` a payload's header must list (invariant 4), as the pinned Keynote
    /// would archive it: every reference in a strong field. A weak occurrence never removes a
    /// reference that is strong elsewhere.
    ///
    /// With `original` (a mutation: the payload and stored list before the edit), two more rules
    /// keep older files safe, since the table describes the pinned Keynote and a record last
    /// archived by an older one may list what 15.4 calls weak:
    /// - a reference that was stored and is still present stays listed (an extra strong edge is
    ///   harmless; a dropped one loses objects);
    /// - in a mixed field, a reference the original held keeps its membership, and a new one is listed.
    /// A field the table does not know is refused only when it holds a reference the original did
    /// not: anything else is decided by the stored list, never by a guess.
    public static func listedObjects(
        _ derived: DerivedReferences,
        strength: ReferenceStrength,
        original: (derived: DerivedReferences, stored: [UInt64])? = nil
    ) throws(ListingFailure) -> Set<UInt64> {
        let originalRefs = Set(original?.derived.objects ?? [])
        let originalListed = Set(original?.stored ?? [])
        var listed = Set<UInt64>()
        for (ref, field) in zip(derived.objects, derived.objectFields) {
            let held = originalRefs.contains(ref)
            if held && originalListed.contains(ref) { listed.insert(ref); continue }
            switch strength.strength(of: field) {
            case .strong:
                listed.insert(ref)
            case .weak:
                break
            case .mixed:
                if !held { listed.insert(ref) }
            case nil:
                if !held { throw .unclassifiedField(field) }
            }
        }
        return listed
    }
}

/// Learns field strength from Keynote-authored payloads and their stored lists.
///
/// An unlisted occurrence proves a field is not strong. A field with unlisted occurrences is weak
/// when every listed occurrence is explained by the same reference sitting in a strong-candidate
/// field of the same payload (the reference was listed for that field's sake); otherwise it is
/// mixed. Fields never seen unlisted are strong.
public struct ReferenceStrengthLearner: Sendable {
    private struct Occurrence: Sendable {
        var field: Int
        var ref: UInt64
        var listed: Bool
    }

    private var fieldIndex: [String: Int] = [:]
    private var fieldNames: [String] = []
    private var payloadOccurrences: [[Occurrence]] = []
    public private(set) var decks = 0

    public init() {}

    public var payloads: Int { payloadOccurrences.count }

    public mutating func observeDeck() { decks += 1 }

    public mutating func observe(_ derived: DerivedReferences, stored: [UInt64]) {
        let listed = Set(stored)
        var occurrences = [Occurrence]()
        for (ref, field) in zip(derived.objects, derived.objectFields) {
            let index: Int
            if let i = fieldIndex[field] {
                index = i
            } else {
                index = fieldNames.count
                fieldIndex[field] = index
                fieldNames.append(field)
            }
            occurrences.append(Occurrence(field: index, ref: ref, listed: listed.contains(ref)))
        }
        payloadOccurrences.append(occurrences)
    }

    public func result(source: String) -> ReferenceStrength.File {
        var occurrences = [Int](repeating: 0, count: fieldNames.count)
        var unlisted = [Int](repeating: 0, count: fieldNames.count)
        for payload in payloadOccurrences {
            for o in payload {
                occurrences[o.field] += 1
                if !o.listed { unlisted[o.field] += 1 }
            }
        }
        let strongCandidate = (0..<fieldNames.count).map { unlisted[$0] == 0 }
        var unexplained = [Int](repeating: 0, count: fieldNames.count)
        for payload in payloadOccurrences {
            let strongRefs = Set(payload.filter { strongCandidate[$0.field] }.map(\.ref))
            for o in payload where !strongCandidate[o.field] && o.listed && !strongRefs.contains(o.ref) {
                unexplained[o.field] += 1
            }
        }
        var fields = [String: ReferenceStrength.File.Field]()
        for (i, name) in fieldNames.enumerated() {
            let strength: ReferenceStrength.Strength = strongCandidate[i] ? .strong : (unexplained[i] == 0 ? .weak : .mixed)
            fields[name] = .init(strength: strength, occurrences: occurrences[i], unlisted: unlisted[i], unexplainedListed: unexplained[i])
        }
        return ReferenceStrength.File(keynoteVersion: Schema.keynoteVersion, source: source, decks: decks, payloads: payloads, fields: fields)
    }
}
