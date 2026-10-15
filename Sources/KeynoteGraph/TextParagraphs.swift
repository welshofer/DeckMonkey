import Foundation
import IWASchema
import SwiftProtobuf

/// Phase 4: set a storage's whole text as paragraphs at list levels (docs/spec.md §9).
///
/// The layout follows what Keynote 15.4 writes for a five-level master body ("Body Level One" …
/// "Body Level Five", every template, and over the corpus slides): paragraphs separated by U+000A;
/// `table_para_data` entries where the list level changes, `first` the level (0 = top level); one
/// `table_para_style` entry per paragraph, the first naming the storage's style and later ones
/// null, which inherit it; and a
/// single entry at 0 for the tables that describe the storage as a whole (list style, paragraph
/// starts and bidi, character style, language, layout style). A manual line break inside a paragraph
/// becomes U+2028, Keynote's line separator.
///
/// The storage's existing styles carry the new text, so it looks as the placeholder's sample text
/// did. Fields (hyperlinks, bookmarks, highlights and the like) go with the old text and are
/// counted. Refused rather than guessed: storages with inline objects (attachments, footnotes),
/// tracked changes, or more than one text string.
public enum TextParagraphs {
    public struct Paragraph: Equatable, Sendable {
        public var text: String
        public var level: Int
        public init(_ text: String, level: Int = 0) { self.text = text; self.level = level }
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case notAStorage(UInt64)
        case multipleTextStrings(Int)
        case anchoredObjects(table: String)
        case trackedChanges
        case noParagraphs
        case levelOutOfRange(Int)
        case invalidOffsets(String)

        public var description: String {
            switch self {
            case .notAStorage(let id): return "object \(id) is not a TSWP.StorageArchive"
            case .multipleTextStrings(let n): return "the storage holds \(n) text strings"
            case .anchoredObjects(let table): return "the storage anchors objects in its text (\(table)); setting its whole text would drop them"
            case .trackedChanges: return "the storage has tracked changes"
            case .noParagraphs: return "no paragraphs to set"
            case .levelOutOfRange(let level): return "list level \(level) is outside 0…8"
            case .invalidOffsets(let detail): return "the new offset tables are invalid: \(detail)"
            }
        }
    }

    /// Keynote's deepest list level in the corpus is 8.
    public static let maximumLevel = 8

    /// `storage` with its text replaced by `paragraphs`, and the number of fields removed.
    public static func apply(_ storage: TSWP_StorageArchive, paragraphs: [Paragraph]) throws(Failure) -> (TSWP_StorageArchive, removedFields: Int) {
        guard storage.text.count <= 1 else { throw .multipleTextStrings(storage.text.count) }
        guard !paragraphs.isEmpty else { throw .noParagraphs }
        if let bad = paragraphs.first(where: { $0.level < 0 || $0.level > maximumLevel }) { throw .levelOutOfRange(bad.level) }
        for (name, table) in [("attachments", storage.tableAttachment), ("footnotes", storage.tableFootnote)] where !table.entries.isEmpty {
            throw .anchoredObjects(table: name)
        }
        if !storage.tableInsertion.entries.isEmpty || !storage.tableDeletion.entries.isEmpty { throw .trackedChanges }

        // The new text and each paragraph's UTF-16 start.
        var text = "", starts = [UInt32]()
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { text += "\n" }
            starts.append(UInt32(text.utf16.count))
            text += p.text.replacingOccurrences(of: "\r\n", with: "\u{2028}")
                .replacingOccurrences(of: "\n", with: "\u{2028}").replacingOccurrences(of: "\r", with: "\u{2028}")
                .replacingOccurrences(of: "\u{2029}", with: "\u{2028}")
        }

        var out = storage
        out.text = [text]
        // One paragraph-style entry per paragraph, as Keynote writes them: the first names the
        // storage's style, later ones are null and inherit it (1,713 null to 300 explicit later
        // entries over the corpus slides).
        if let first = storage.tableParaStyle.entries.first {
            out.tableParaStyle.entries = starts.enumerated().map { i, start in
                if i == 0 { var e = first; e.characterIndex = 0; return e }
                return TSWP_ObjectAttributeTable.ObjectAttribute.with { $0.characterIndex = start }
            }
        }
        // Paragraph data carries the list level, with an entry where the level changes (the table
        // is created only when a level needs it; every corpus storage has it).
        if storage.hasTableParaData || paragraphs.contains(where: { $0.level > 0 }) {
            var entries = [TSWP_ParaDataAttributeTable.ParaDataAttribute]()
            for (start, p) in zip(starts, paragraphs) where entries.last.map({ $0.first != UInt32(p.level) }) ?? true {
                entries.append(.with { $0.characterIndex = start; $0.first = UInt32(p.level); $0.second = 0 })
            }
            out.tableParaData.entries = entries
        }
        // Whole-storage tables keep the entry in force at 0.
        func first(_ t: TSWP_ObjectAttributeTable) -> TSWP_ObjectAttributeTable {
            var t2 = t
            t2.entries = Array(t.entries.filter { $0.characterIndex == 0 }.prefix(1))
            return t2
        }
        func first(_ t: TSWP_ParaDataAttributeTable) -> TSWP_ParaDataAttributeTable {
            var t2 = t
            t2.entries = Array(t.entries.filter { $0.characterIndex == 0 }.prefix(1))
            return t2
        }
        func first(_ t: TSWP_StringAttributeTable) -> TSWP_StringAttributeTable {
            var t2 = t
            t2.entries = Array(t.entries.filter { $0.characterIndex == 0 }.prefix(1))
            return t2
        }
        if storage.hasTableListStyle { out.tableListStyle = first(storage.tableListStyle) }
        if storage.hasTableCharStyle { out.tableCharStyle = first(storage.tableCharStyle) }
        if storage.hasTableLayoutStyle { out.tableLayoutStyle = first(storage.tableLayoutStyle) }
        if storage.hasTableDropCapStyle { out.tableDropCapStyle = first(storage.tableDropCapStyle) }
        if storage.hasTableParaStarts { out.tableParaStarts = first(storage.tableParaStarts) }
        if storage.hasTableParaBidi { out.tableParaBidi = first(storage.tableParaBidi) }
        if storage.hasTableLanguage { out.tableLanguage = first(storage.tableLanguage) }
        if storage.hasTableDictation { out.tableDictation = first(storage.tableDictation) }
        // Fields belonged to the old text. Only tables the storage has are touched: writing an
        // absent table back (even empty, as an inout access does) creates it, and Keynote then
        // treats the storage as needing an upgrade on read.
        var removed = 0
        func cleared(_ t: TSWP_ObjectAttributeTable) -> TSWP_ObjectAttributeTable {
            removed += t.entries.filter { $0.hasObject && $0.object.identifier != 0 }.count
            var empty = t
            empty.entries = []
            return empty
        }
        if storage.hasTableSmartfield { out.tableSmartfield = cleared(storage.tableSmartfield) }
        if storage.hasTableBookmark { out.tableBookmark = cleared(storage.tableBookmark) }
        if storage.hasTableHighlight { out.tableHighlight = cleared(storage.tableHighlight) }
        if storage.hasTableRubyfield { out.tableRubyfield = cleared(storage.tableRubyfield) }
        if storage.hasTableTatechuyoko { out.tableTatechuyoko = cleared(storage.tableTatechuyoko) }
        if storage.hasTableOverlappingHighlight {
            removed += storage.tableOverlappingHighlight.entries.count
            var t = storage.tableOverlappingHighlight; t.entries = []; out.tableOverlappingHighlight = t
        }
        if storage.hasTablePencilAnnotation {
            removed += storage.tablePencilAnnotation.entries.count
            var t = storage.tablePencilAnnotation; t.entries = []; out.tablePencilAnnotation = t
        }

        if let problem = TextOffsets.problems(in: out).first { throw .invalidOffsets("\(problem)") }
        return (out, removed)
    }
}

extension KeynoteDocument {
    /// Sets storage `identifier`'s whole text to `paragraphs` (see `TextParagraphs`). The header
    /// is rebuilt from the new bytes by `replacePayload` (invariant 4).
    @discardableResult
    public mutating func setParagraphs(in identifier: UInt64, _ paragraphs: [TextParagraphs.Paragraph]) throws -> Int {
        let storage: TSWP_StorageArchive
        do { storage = try storageArchive(identifier) } catch { throw TextParagraphs.Failure.notAStorage(identifier) }
        let (edited, removed) = try TextParagraphs.apply(storage, paragraphs: paragraphs)
        try replacePayload(of: identifier, with: try edited.serializedData(partial: true))
        return removed
    }
}
