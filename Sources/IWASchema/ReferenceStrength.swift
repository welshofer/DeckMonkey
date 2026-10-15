import Foundation

/// Which `TSP.Reference` fields Keynote lists in `MessageInfo.object_references` (invariant 4).
///
/// Keynote lists strong references only. Strength is a property of the archiving code, not of the
/// schema (no field option marks it), so it is learned from Keynote-authored files by
/// `deckmonkey reference-strength` into `Registry/reference-strength-<version>.json`, the same way
/// the registry is extracted rather than written. Keys are `<message full name>.<field number>`.
public struct ReferenceStrength: Sendable, Equatable {
    public enum Strength: String, Sendable, Codable {
        /// Always listed when present.
        case strong
        /// Never listed: back-pointers to parents and owners, UI state. May dangle.
        case weak
        /// Listed in some records and not others; no rule recovered yet. Mutations preserve the
        /// stored membership of references that were already there.
        case mixed
    }

    public let keynoteVersion: String
    public let fields: [String: Strength]

    public init(keynoteVersion: String, fields: [String: Strength]) {
        self.keynoteVersion = keynoteVersion
        self.fields = fields
    }

    public func strength(of field: String) -> Strength? { fields[field] }

    /// The on-disk form: the classification plus the evidence it was learned from.
    public struct File: Codable, Sendable, Equatable {
        public struct Field: Codable, Sendable, Equatable {
            public var strength: Strength
            /// References seen in this field across the corpus.
            public var occurrences: Int
            /// Of those, how many the stored list left out.
            public var unlisted: Int
            /// Listed occurrences not explained by the same reference in a strong field.
            public var unexplainedListed: Int

            public init(strength: Strength, occurrences: Int, unlisted: Int, unexplainedListed: Int) {
                self.strength = strength
                self.occurrences = occurrences
                self.unlisted = unlisted
                self.unexplainedListed = unexplainedListed
            }
        }

        public var keynoteVersion: String
        public var source: String
        public var decks: Int
        public var payloads: Int
        public var fields: [String: Field]

        public init(keynoteVersion: String, source: String, decks: Int, payloads: Int, fields: [String: Field]) {
            self.keynoteVersion = keynoteVersion
            self.source = source
            self.decks = decks
            self.payloads = payloads
            self.fields = fields
        }

        /// Deterministic: sorted keys, so a re-run on the same corpus leaves git clean.
        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(self)
            data.append(0x0A)
            return data
        }
    }

    /// Loads `reference-strength-<version>.json` from the module bundle.
    public static func load(version: String) throws -> ReferenceStrength {
        guard let url = Bundle.module.url(forResource: "reference-strength-\(version)", withExtension: "json", subdirectory: "Registry") else {
            throw SchemaError.registryNotFound("reference-strength-\(version)")
        }
        return try load(from: Data(contentsOf: url))
    }

    public static func load(from json: Data) throws -> ReferenceStrength {
        let file = try JSONDecoder().decode(File.self, from: json)
        return ReferenceStrength(keynoteVersion: file.keynoteVersion, fields: file.fields.mapValues(\.strength))
    }
}
