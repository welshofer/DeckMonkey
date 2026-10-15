import Foundation
import SwiftProtobuf

/// For every message in the pinned schema, which field numbers hold sub-messages and of what type,
/// extensions included. Built from the descriptors `make schema` extracted (shipped as
/// `Registry/descriptors-<version>.pb`), so code can walk a payload at the wire level and touch
/// only what it means to: the clone's reference rewriter changes `TSP.Reference` and `TSP.UUID`
/// values and copies every other byte as it was.
public struct FieldIndex: Sendable {
    /// Message full name ("KN.SlideArchive") → field number → sub-message full name.
    public let messageFields: [String: [Int: String]]
    /// Message full name → field number → field name, for every `uint32` field (the calculation
    /// engine's internal owner identifiers are uint32 fields named `…owner_id…`).
    public let uint32Fields: [String: [Int: String]]

    public func subMessage(of message: String, field: Int) -> String? { messageFields[message]?[field] }

    public static func load(version: String) throws -> FieldIndex {
        guard let url = Bundle.module.url(forResource: "descriptors-\(version)", withExtension: "pb", subdirectory: "Registry") else {
            throw SchemaError.registryNotFound("descriptors-\(version)")
        }
        return try FieldIndex(descriptors: Data(contentsOf: url))
    }

    public init(descriptors: Data) throws {
        let set = try Google_Protobuf_FileDescriptorSet(serializedBytes: descriptors)
        var fields = [String: [Int: String]]()
        var uint32s = [String: [Int: String]]()
        func strip(_ name: String) -> String { name.hasPrefix(".") ? String(name.dropFirst()) : name }
        func add(_ field: Google_Protobuf_FieldDescriptorProto, to message: String) {
            guard field.type == .message || field.type == .group else { return }
            fields[message, default: [:]][Int(field.number)] = strip(field.typeName)
        }
        func walk(_ message: Google_Protobuf_DescriptorProto, prefix: String) {
            let name = prefix.isEmpty ? message.name : "\(prefix).\(message.name)"
            fields[name, default: [:]] = fields[name] ?? [:]
            message.field.forEach { add($0, to: name) }
            for f in message.field where f.type == .uint32 { uint32s[name, default: [:]][Int(f.number)] = f.name }
            message.extension.forEach { add($0, to: strip($0.extendee)) }
            message.nestedType.forEach { walk($0, prefix: name) }
        }
        for file in set.file {
            file.messageType.forEach { walk($0, prefix: file.package) }
            file.extension.forEach { add($0, to: strip($0.extendee)) }
        }
        messageFields = fields
        uint32Fields = uint32s
    }
}
