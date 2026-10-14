import Foundation
import IWASnappy

/// Errors from decoding the `TSP.ArchiveInfo` / `TSP.MessageInfo` headers.
public enum ArchiveInfoError: Error, Equatable, Sendable {
    case missingIdentifier
    case missingType(messageIndex: Int)
    case missingLength(messageIndex: Int)
}

/// `TSP.MessageInfo`: one payload's type, versions, length and the references it contains.
///
/// Known field numbers (verify against the pinned schema; docs/spec.md §4):
/// 1 type, 2 version (repeated), 3 length, 4 field_infos, 5 object_references (repeated),
/// 6 data_references (repeated), 7 base_message_index, 8 diff_merge_version.
/// `fields` is the source of truth and is re-emitted verbatim; the typed properties are views.
/// Mutate through the `set…` helpers so both stay consistent (invariant 4: reference lists are derived).
public struct MessageInfo: Equatable, Sendable {
    public static let typeField = 1
    public static let versionField = 2
    public static let lengthField = 3
    public static let fieldInfosField = 4
    public static let objectReferencesField = 5
    public static let dataReferencesField = 6
    public static let baseMessageIndexField = 7

    public private(set) var fields: [WireField]
    public private(set) var type: UInt32
    public private(set) var version: [UInt32]
    public private(set) var length: UInt32
    public private(set) var objectReferences: [UInt64]
    public private(set) var dataReferences: [UInt64]
    public private(set) var baseMessageIndex: UInt32?

    public init(fields: [WireField], messageIndex: Int = 0) throws {
        self.fields = fields
        var type: UInt32?
        var version = [UInt32]()
        var length: UInt32?
        var objectReferences = [UInt64]()
        var dataReferences = [UInt64]()
        var baseMessageIndex: UInt32?
        for field in fields {
            switch field.number {
            case Self.typeField:
                if case .varint(let v) = field.value { type = UInt32(truncatingIfNeeded: v) }
            case Self.versionField:
                version.append(contentsOf: try Wire.repeatedVarints(field.value).map { UInt32(truncatingIfNeeded: $0) })
            case Self.lengthField:
                if case .varint(let v) = field.value { length = UInt32(truncatingIfNeeded: v) }
            case Self.objectReferencesField:
                objectReferences.append(contentsOf: try Wire.repeatedVarints(field.value))
            case Self.dataReferencesField:
                dataReferences.append(contentsOf: try Wire.repeatedVarints(field.value))
            case Self.baseMessageIndexField:
                if case .varint(let v) = field.value { baseMessageIndex = UInt32(truncatingIfNeeded: v) }
            default:
                break
            }
        }
        guard let type else { throw ArchiveInfoError.missingType(messageIndex: messageIndex) }
        guard let length else { throw ArchiveInfoError.missingLength(messageIndex: messageIndex) }
        self.type = type
        self.version = version
        self.length = length
        self.objectReferences = objectReferences
        self.dataReferences = dataReferences
        self.baseMessageIndex = baseMessageIndex
    }

    /// Builds a minimal header for a new payload. Reference lists start empty; derive them before save.
    public init(type: UInt32, version: [UInt32], length: UInt32) {
        var fields = [WireField]()
        fields.append(WireField(number: Self.typeField, value: .varint(UInt64(type))))
        if !version.isEmpty {
            fields.append(WireField(number: Self.versionField, value: Wire.packed(version.map { UInt64($0) })))
        }
        fields.append(WireField(number: Self.lengthField, value: .varint(UInt64(length))))
        self.fields = fields
        self.type = type
        self.version = version
        self.length = length
        self.objectReferences = []
        self.dataReferences = []
        self.baseMessageIndex = nil
    }

    public func encoded() -> [UInt8] {
        return Wire.encode(fields)
    }

    public mutating func setLength(_ newLength: UInt32) {
        length = newLength
        replace(number: Self.lengthField, with: [.varint(UInt64(newLength))])
    }

    /// Replaces the object reference list, written packed (Keynote writes these packed).
    public mutating func setObjectReferences(_ refs: [UInt64]) {
        objectReferences = refs
        replace(number: Self.objectReferencesField, with: refs.isEmpty ? [] : [Wire.packed(refs)])
    }

    public mutating func setDataReferences(_ refs: [UInt64]) {
        dataReferences = refs
        replace(number: Self.dataReferencesField, with: refs.isEmpty ? [] : [Wire.packed(refs)])
    }

    /// Replaces every occurrence of field `number` with `values`, keeping the first occurrence's
    /// position (or appending in field-number order when the field was absent).
    private mutating func replace(number: Int, with values: [WireField.Value]) {
        let replacement = values.map { WireField(number: number, value: $0) }
        if let first = fields.firstIndex(where: { $0.number == number }) {
            fields.removeAll { $0.number == number }
            fields.insert(contentsOf: replacement, at: min(first, fields.count))
        } else {
            let insertAt = fields.firstIndex(where: { $0.number > number }) ?? fields.count
            fields.insert(contentsOf: replacement, at: insertAt)
        }
    }
}

/// `TSP.ArchiveInfo`: the header that precedes each object's payloads in an archive stream.
///
/// Known field numbers: 1 identifier, 2 message_infos (repeated), 3 should_merge.
public struct ArchiveInfo: Equatable, Sendable {
    public static let identifierField = 1
    public static let messageInfosField = 2
    public static let shouldMergeField = 3

    /// Every field as read; entries for field 2 are placeholders whose bytes are regenerated from
    /// `messageInfos` on encode so a mutated `MessageInfo` is always what gets written.
    public private(set) var fields: [WireField]
    public private(set) var identifier: UInt64
    public var messageInfos: [MessageInfo]
    public private(set) var shouldMerge: Bool

    public init(bytes: [UInt8]) throws {
        let fields = try Wire.fields(bytes)
        var identifier: UInt64?
        var messageInfos = [MessageInfo]()
        var shouldMerge = false
        for field in fields {
            switch field.number {
            case Self.identifierField:
                if case .varint(let v) = field.value { identifier = v }
            case Self.messageInfosField:
                if case .lengthDelimited(let data) = field.value {
                    messageInfos.append(try MessageInfo(fields: try Wire.fields([UInt8](data)), messageIndex: messageInfos.count))
                }
            case Self.shouldMergeField:
                if case .varint(let v) = field.value { shouldMerge = v != 0 }
            default:
                break
            }
        }
        guard let identifier else { throw ArchiveInfoError.missingIdentifier }
        self.fields = fields
        self.identifier = identifier
        self.messageInfos = messageInfos
        self.shouldMerge = shouldMerge
    }

    /// A fresh header for a new object (never a merge record; invariant: writes are consolidated).
    public init(identifier: UInt64, messageInfos: [MessageInfo]) {
        self.fields = [
            WireField(number: Self.identifierField, value: .varint(identifier)),
        ] + messageInfos.map { WireField(number: Self.messageInfosField, value: .lengthDelimited(Data($0.encoded()))) }
        self.identifier = identifier
        self.messageInfos = messageInfos
        self.shouldMerge = false
    }

    /// Serializes the header. Untouched headers re-encode byte-identically to what was read
    /// (minimal varints both ways); mutated `messageInfos` replace the field-2 entries in order.
    public func encoded() -> [UInt8] {
        var out = [WireField]()
        var infoIndex = 0
        for field in fields {
            if field.number == Self.messageInfosField {
                if infoIndex < messageInfos.count {
                    out.append(WireField(number: Self.messageInfosField, value: .lengthDelimited(Data(messageInfos[infoIndex].encoded()))))
                }
                infoIndex += 1
            } else {
                out.append(field)
            }
        }
        // Message infos added beyond what was read go at the end of the field-2 run.
        while infoIndex < messageInfos.count {
            let value = WireField(number: Self.messageInfosField, value: .lengthDelimited(Data(messageInfos[infoIndex].encoded())))
            let insertAt = out.lastIndex(where: { $0.number <= Self.messageInfosField }).map { $0 + 1 } ?? out.count
            out.insert(value, at: insertAt)
            infoIndex += 1
        }
        return Wire.encode(out)
    }

    /// Rewrites the identifier (used when cloning subgraphs with fresh identifiers).
    public mutating func setIdentifier(_ newIdentifier: UInt64) {
        identifier = newIdentifier
        if let i = fields.firstIndex(where: { $0.number == Self.identifierField }) {
            fields[i] = WireField(number: Self.identifierField, value: .varint(newIdentifier))
        } else {
            fields.insert(WireField(number: Self.identifierField, value: .varint(newIdentifier)), at: 0)
        }
    }

    /// Clears the merge flag. Consolidated saves never emit merge records.
    public mutating func clearShouldMerge() {
        shouldMerge = false
        fields.removeAll { $0.number == Self.shouldMergeField }
    }
}
