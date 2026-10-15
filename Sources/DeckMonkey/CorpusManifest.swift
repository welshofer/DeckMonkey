import Foundation

/// `Corpus/manifest.json`: what `deckmonkey corpus add` recorded about each in-repo corpus deck
/// (docs/spec.md §11). Deterministic (sorted keys) so re-adding an unchanged deck leaves git clean.
public struct CorpusManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// SHA-256 of the deck: the file for a zip; for a package directory, of every entry's
        /// relative path and bytes in sorted order.
        public var sha256: String
        /// Last `BuildVersionHistory` entry, e.g. "M15.4-7051.0.79-2".
        public var savedBy: String
        public var fileFormatVersion: String
        /// The Keynote whose export is the golden PDF (`<deck>.golden.pdf`, rebuilt locally by
        /// `make goldens`, never committed).
        public var oracleKeynote: String

        public init(sha256: String, savedBy: String, fileFormatVersion: String, oracleKeynote: String) {
            self.sha256 = sha256
            self.savedBy = savedBy
            self.fileFormatVersion = fileFormatVersion
            self.oracleKeynote = oracleKeynote
        }
    }

    /// Keyed by path relative to `Corpus/`, e.g. "templates/basic-white_wide.key".
    public var decks: [String: Entry]

    public init(decks: [String: Entry] = [:]) {
        self.decks = decks
    }

    public static func load(_ url: URL) throws -> CorpusManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return CorpusManifest() }
        return try JSONDecoder().decode(CorpusManifest.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    /// SHA-256 of a deck in either container form.
    public static func digest(of deck: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: deck.path, isDirectory: &isDirectory) else {
            throw IWAPackageError.notFound(deck.path)
        }
        guard isDirectory.boolValue else { return SHA256.hex(try Data(contentsOf: deck)) }
        var paths = [String]()
        let base = deck.standardizedFileURL.path
        if let walker = FileManager.default.enumerator(atPath: base) {
            for case let path as String in walker {
                var dir: ObjCBool = false
                if FileManager.default.fileExists(atPath: base + "/" + path, isDirectory: &dir), !dir.boolValue { paths.append(path) }
            }
        }
        var blob = Data()
        for path in paths.sorted() {
            blob.append(Data(path.utf8))
            blob.append(0)
            blob.append(try Data(contentsOf: URL(fileURLWithPath: base + "/" + path)))
        }
        return SHA256.hex(blob)
    }
}
