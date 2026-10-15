import Foundation
import SwiftProtobuf

/// Maps IWA message type numbers to archive class names for one Keynote build.
///
/// Keynote keeps this table in its `TSPRegistry` runtime object; `Scripts/registry-dump` extracts
/// it (docs/spec.md §7 step 4) into `Registry/registry-<version>.json`. The generated SwiftProtobuf
/// sources for the same build live under `Generated/<version>/` and are produced by `make schema`;
/// neither is hand-edited. Until the first extraction runs, the shipped registry is empty and
/// every type decodes through the raw store only.
public struct TypeRegistry: Sendable, Equatable {
    public let keynoteVersion: String
    public let types: [UInt32: String]

    public init(keynoteVersion: String, types: [UInt32: String]) {
        self.keynoteVersion = keynoteVersion
        self.types = types
    }

    public func name(for type: UInt32) -> String? { types[type] }

    public var isEmpty: Bool { types.isEmpty }

    /// Loads `registry-<version>.json` from the module bundle.
    public static func load(version: String) throws -> TypeRegistry {
        guard let url = Bundle.module.url(forResource: "registry-\(version)", withExtension: "json", subdirectory: "Registry") else {
            throw SchemaError.registryNotFound(version)
        }
        return try load(from: Data(contentsOf: url))
    }

    public static func load(from json: Data) throws -> TypeRegistry {
        struct File: Decodable {
            let keynoteVersion: String
            let types: [String: String]
        }
        let file = try JSONDecoder().decode(File.self, from: json)
        var types = [UInt32: String]()
        for (key, value) in file.types {
            guard let number = UInt32(key) else { throw SchemaError.badTypeNumber(key) }
            types[number] = value
        }
        return TypeRegistry(keynoteVersion: file.keynoteVersion, types: types)
    }

    /// The registry pinned for Phase 0 (docs/spec.md OQ-2).
    public static let pinnedVersion = "15.4"
}

public enum SchemaError: Error, Equatable, Sendable {
    case registryNotFound(String)
    case badTypeNumber(String)
    /// The file was written by a Keynote newer than any pinned schema; it is read-only (AT-25).
    case schemaNewerThanLibrary(fileBuild: String, pinned: String)
}

/// The SwiftProtobuf runtime version the generated sources were built against, exposed so
/// `deckmonkey inspect` can report it.
public enum SchemaRuntime {
    public static var protobufVersion: String {
        "\(SwiftProtobuf.Version.major).\(SwiftProtobuf.Version.minor).\(SwiftProtobuf.Version.revision)"
    }
}
