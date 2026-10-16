import Foundation
@_exported import IWAArchive
@_exported import IWAContainer
@_exported import IWASchema
@_exported import LecternIR
@_exported import KeynoteGraph

/// DeckMonkey — read and write native Keynote files from Swift.
///
/// Phase 0 surface: open a `.key`, inspect it, validate it, save it (lossless round-trip).
/// The Deck IR bridge to Rostrum's `DeckOutline` lands in Phase 4 (docs/spec.md §12).
public enum DeckMonkey {
    public static let version = "0.1.0"

    /// Opens a Keynote file or package directory.
    public static func open(_ url: URL) throws -> KeynoteDocument {
        try KeynoteDocument.open(url)
    }

    /// Opens, saves to `output`, re-opens, and reports whether every component survived unchanged.
    public static func roundTrip(_ input: URL, to output: URL) throws -> RoundTripReport {
        let original = try KeynoteDocument.open(input)
        try original.save(to: output)
        let reread = try KeynoteDocument.open(output)

        var report = RoundTripReport()
        let originalComponents = Dictionary(uniqueKeysWithValues: original.store.joinedComponents().map { ($0.name, $0.decompressed) })
        let rereadComponents = Dictionary(uniqueKeysWithValues: reread.store.joinedComponents().map { ($0.name, $0.decompressed) })
        for name in original.package.iwaNames {
            guard let a = originalComponents[name] else { continue }
            if let b = rereadComponents[name], a == b {
                report.identical.append(name)
            } else {
                let firstDifference = firstDifferingIdentifier(original.store.records(in: name) ?? [], reread.store.records(in: name) ?? [])
                report.different.append(RoundTripReport.Difference(component: name, firstDifferingIdentifier: firstDifference))
            }
        }
        for name in original.package.entryNames where !name.hasSuffix(".iwa") {
            if original.package.data(name) != reread.package.data(name) {
                report.different.append(RoundTripReport.Difference(component: name, firstDifferingIdentifier: nil))
            }
        }
        for name in reread.package.entryNames where original.package.data(name) == nil {
            report.different.append(RoundTripReport.Difference(component: name, firstDifferingIdentifier: nil))
        }
        return report
    }

    private static func firstDifferingIdentifier(_ a: [ArchiveRecord], _ b: [ArchiveRecord]) -> UInt64? {
        for (x, y) in zip(a, b) where x != y {
            return x.identifier
        }
        if a.count != b.count {
            return (a.count > b.count ? a[b.count] : b[a.count]).identifier
        }
        return nil
    }
}

/// Result of `DeckMonkey.roundTrip`: `isClean` is Gate 0's `roundtrip CLEAN n/n`.
public struct RoundTripReport: Sendable, Equatable {
    public struct Difference: Sendable, Equatable {
        public let component: String
        public let firstDifferingIdentifier: UInt64?
    }

    public var identical: [String] = []
    public var different: [Difference] = []

    public var isClean: Bool { different.isEmpty }

    public var summaryLine: String {
        if isClean {
            return "CLEAN \(identical.count)/\(identical.count)"
        }
        let total = identical.count + different.count
        let first = different[0]
        let where_ = first.firstDifferingIdentifier.map { " (first differing identifier \($0))" } ?? ""
        return "DIFFERENT \(identical.count)/\(total) identical; first difference in \(first.component)\(where_)"
    }
}
