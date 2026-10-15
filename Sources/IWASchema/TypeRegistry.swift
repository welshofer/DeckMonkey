import Foundation
import SwiftProtobuf

/// Maps IWA message type numbers to protobuf message names for one Keynote build.
///
/// Keynote fills this table in its `TSPRegistry` at launch. `Scripts/schema/registry-dump.py`
/// recovers it statically from the registration calls in the binary (docs/spec.md §7 step 4)
/// into `Registry/registry-<version>.json`; the generated SwiftProtobuf sources for the same build
/// live under `Generated/<version>/`. Neither is hand-edited.
public struct TypeRegistry: Sendable, Equatable {
    public let keynoteVersion: String
    /// Type number → full proto message name, e.g. 1 → "KN.DocumentArchive".
    public let types: [UInt32: String]
    /// Types this Keynote registers as deprecated (`-[TSPRegistry setDeprecatedMessageType:]`): it
    /// knows them and has no schema for them. Old files carry them (6219 in decks last saved by
    /// Keynote 6.5); they live on in the raw store, byte for byte, like anything not understood.
    public let deprecatedTypes: Set<UInt32>

    public init(keynoteVersion: String, types: [UInt32: String], deprecatedTypes: Set<UInt32> = []) {
        self.keynoteVersion = keynoteVersion
        self.types = types
        self.deprecatedTypes = deprecatedTypes
    }

    public func name(for type: UInt32) -> String? { types[type] }

    /// AT-05: a type resolves when this Keynote has a message for it or declares it deprecated.
    public func resolves(_ type: UInt32) -> Bool { types[type] != nil || deprecatedTypes.contains(type) }

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
            let deprecatedTypes: [UInt32]?
        }
        let file = try JSONDecoder().decode(File.self, from: json)
        var types = [UInt32: String]()
        for (key, value) in file.types {
            guard let number = UInt32(key) else { throw SchemaError.badTypeNumber(key) }
            types[number] = value
        }
        return TypeRegistry(keynoteVersion: file.keynoteVersion, types: types, deprecatedTypes: Set(file.deprecatedTypes ?? []))
    }

    /// The registry pinned for Phase 0 (docs/spec.md OQ-2).
    public static let pinnedVersion = "15.4"
    public static let pinnedBuild = "7051.0.79"

    /// What Keynote 15.4 (7051.0.79) writes into `TSP.PackageMetadata` (read 2.4.0, write 4.1.0,
    /// file format 26.4.0; observed in every deck it saved). A file whose `write_version` or
    /// `file_format_version` exceeds these was written by a newer Keynote than the schema: it opens
    /// through the raw store and refuses writes (AT-25).
    public static let pinnedWriteVersion: [UInt32] = [4, 1, 0]
    public static let pinnedFileFormatVersion: [UInt32] = [26, 4, 0]

    /// Version arrays compare component-wise, missing components counting as 0.
    public static func isNewer(_ version: [UInt32], than pinned: [UInt32]) -> Bool {
        for i in 0..<max(version.count, pinned.count) {
            let a = i < version.count ? version[i] : 0, b = i < pinned.count ? pinned[i] : 0
            if a != b { return a > b }
        }
        return false
    }
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

extension SchemaError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .registryNotFound(let version): return "no type registry for Keynote \(version)"
        case .badTypeNumber(let value): return "registry type number \(value) is not an integer"
        case .schemaNewerThanLibrary(let fileBuild, let pinned):
            return "saved by \(fileBuild), newer than the pinned schema \(pinned); read-only"
        }
    }
}
