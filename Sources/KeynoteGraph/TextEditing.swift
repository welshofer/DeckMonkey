import Foundation
import IWASchema
import SwiftProtobuf

/// Phase 1: find and replace text in a document's `TSWP.StorageArchive`s (docs/spec.md §9).
extension KeynoteDocument {
    public struct TextMatch: Equatable, Sendable {
        public var storage: UInt64
        /// UTF-16 offsets into the storage's text.
        public var range: Range<Int>
    }

    public struct ReplaceSummary: Equatable, Sendable {
        public var replacements = 0
        public var storages: [UInt64] = []
        public var removedFields: [UInt64] = []
        public var collapsedEntries = 0
    }

    static let storageType: UInt32 = 2001

    /// Every text storage with its text, in component order.
    public var textStorages: [(identifier: UInt64, text: String)] {
        var out = [(UInt64, String)]()
        for component in store.components {
            for record in component.records {
                guard let info = record.info.messageInfos.first, info.type == Self.storageType, info.baseMessageIndex == nil,
                      let s = try? TSWP_StorageArchive(serializedBytes: record.payloads[0], extensions: Schema.extensions, partial: true)
                else { continue }
                out.append((record.identifier, s.text.joined()))
            }
        }
        return out
    }

    /// Every occurrence of `needle`, optionally in one storage.
    public func find(_ needle: String, in storage: UInt64? = nil) -> [TextMatch] {
        textStorages.filter { storage == nil || $0.identifier == storage }.flatMap { s in
            TextReplace.occurrences(of: needle, in: s.text).map { TextMatch(storage: s.identifier, range: $0) }
        }
    }

    func storageArchive(_ identifier: UInt64) throws -> TSWP_StorageArchive {
        guard let record = store.record(for: identifier), let info = record.info.messageInfos.first,
              info.type == Self.storageType, info.baseMessageIndex == nil else {
            throw TextReplace.Failure.notAStorage(identifier)
        }
        return try TSWP_StorageArchive(serializedBytes: record.payloads[0], extensions: Schema.extensions, partial: true)
    }

    /// Replaces UTF-16 `range` of storage `identifier`'s text. The header (length, reference lists)
    /// is rebuilt from the new bytes by `replacePayload` (invariant 4).
    @discardableResult
    public mutating func replaceText(in identifier: UInt64, range: Range<Int>, with replacement: String) throws -> TextReplace.Report {
        let (edited, report) = try TextReplace.apply(try storageArchive(identifier), range: range, with: replacement)
        try replacePayload(of: identifier, with: try edited.serializedData(partial: true))
        return report
    }

    /// Replaces every occurrence of `needle` (optionally in one storage). Within a storage the
    /// matches are applied last to first, so earlier ranges stay valid; one payload rewrite each.
    @discardableResult
    public mutating func replaceAll(_ needle: String, with replacement: String, in storage: UInt64? = nil) throws -> ReplaceSummary {
        var summary = ReplaceSummary()
        let byStorage = Dictionary(grouping: find(needle, in: storage), by: \.storage)
        for id in byStorage.keys.sorted() {
            var archive = try storageArchive(id)
            for match in byStorage[id]!.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                let (edited, report) = try TextReplace.apply(archive, range: match.range, with: replacement)
                archive = edited
                summary.replacements += 1
                summary.removedFields += report.removedFields
                summary.collapsedEntries += report.collapsedEntries
            }
            try replacePayload(of: id, with: try archive.serializedData(partial: true))
            summary.storages.append(id)
        }
        return summary
    }
}
