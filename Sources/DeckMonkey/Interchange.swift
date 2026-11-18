import Foundation
@_exported import KeynoteInterchange

/// Format boundaries are explicit: opening interchange never converts a native document.
public enum KeynoteFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    case expectedInterchange(path: String)
    case nativeOperationOnInterchange(path: String)

    public var description: String {
        switch self {
        case .expectedInterchange(let path):
            return "Expected a .keyx interchange path, not \(path). Native .key and PPTX conversion is not supported."
        case .nativeOperationOnInterchange(let path):
            return "\(path) is an interchange (.keyx) path. Use the explicit interchange API or 'deckmonkey keyx'; native .key operations do not convert it."
        }
    }
}

public extension DeckMonkey {
    /// Opens Apple's ZIP/JSON interchange format. Native `.key` continues to use `open`.
    /// Inspect, edit, render and save with the re-exported `KeynoteInterchange` value API.
    static func openInterchange(_ url: URL, limits: KeyxLimits = .default) throws -> KeyxDocument {
        try requireInterchangePath(url)
        return try KeyxDocument(contentsOf: url, limits: limits)
    }

    /// Saves and reopens a `.keyx`, comparing uncompressed entry bytes, not ZIP encoding.
    /// The shared writer adds default manifest/presets entries when they were absent.
    static func roundTripInterchange(_ input: URL, to output: URL,
                                    limits: KeyxLimits = .default) throws -> InterchangeRoundTripReport {
        try requireInterchangePath(output)
        let original = try openInterchange(input, limits: limits)
        try original.save(to: output)
        let reopened = try openInterchange(output, limits: limits)
        return InterchangeRoundTripReport(original: original, reopened: reopened)
    }

    private static func requireInterchangePath(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "keyx" else {
            throw KeynoteFormatError.expectedInterchange(path: url.path)
        }
    }
}

/// Same-format byte preservation; this does not assert native Keynote acceptance or visual fidelity.
public struct InterchangeRoundTripReport: Equatable, Sendable {
    public let identical: [String]
    public let changed: [String]
    public let removed: [String]
    public let added: [String]

    public var preservesOriginalEntries: Bool { changed.isEmpty && removed.isEmpty }
    public var isIdentical: Bool { preservesOriginalEntries && added.isEmpty }

    init(original: KeyxDocument, reopened: KeyxDocument) {
        // archiveEntryNames includes optional JSON names even when they are not in the input.
        let before = Set(original.archiveEntryNames.filter { original.entryData(named: $0) != nil })
        let after = Set(reopened.archiveEntryNames.filter { reopened.entryData(named: $0) != nil })
        let shared = before.intersection(after).sorted()
        identical = shared.filter { original.entryData(named: $0) == reopened.entryData(named: $0) }
        changed = shared.filter { original.entryData(named: $0) != reopened.entryData(named: $0) }
        removed = before.subtracting(after).sorted()
        added = after.subtracting(before).sorted()
    }
}
