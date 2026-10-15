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
