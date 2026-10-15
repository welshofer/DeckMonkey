import Foundation
import IWASchema
import SwiftProtobuf

/// Invariant 8 for text: a `TSWP.StorageArchive`'s attribute tables are offset tables into its
/// text, which iWork indexes in UTF-16 code units. Every table's `character_index` values must be
/// strictly increasing and at most the text length; every overlapping range must lie within it.
public enum TextOffsets {
    public struct Problem: Equatable, Sendable, CustomStringConvertible {
        public enum Kind: Equatable, Sendable {
            case unsorted(previous: UInt32, next: UInt32)
            case pastEnd(index: UInt32)
            case rangePastEnd(location: UInt32, length: UInt32)
        }

        /// The table's field name in `TSWP.StorageArchive`, e.g. "table_para_style".
        public let table: String
        public let kind: Kind
        public let textLength: Int

        public var description: String {
            switch kind {
            case .unsorted(let previous, let next):
                return "\(table): offset \(next) follows \(previous) (text length \(textLength))"
            case .pastEnd(let index):
                return "\(table): offset \(index) past text length \(textLength)"
            case .rangePastEnd(let location, let length):
                return "\(table): range \(location)+\(length) past text length \(textLength)"
            }
        }
    }

    /// One offset-table entry: where it starts, and the object it attaches there (a style, a
    /// field, an attachment), if any. Paragraph-data and string tables carry no object.
    public struct Entry: Equatable, Sendable {
        public var index: UInt32
        public var object: UInt64?
    }

    /// Every character-indexed table of a storage, by field name, in field order.
    public static func tables(of s: TSWP_StorageArchive) -> [(name: String, entries: [Entry])] {
        func object(_ t: TSWP_ObjectAttributeTable) -> [Entry] {
            t.entries.map { Entry(index: $0.characterIndex, object: $0.hasObject ? $0.object.identifier : nil) }
        }
        func paraData(_ t: TSWP_ParaDataAttributeTable) -> [Entry] { t.entries.map { Entry(index: $0.characterIndex, object: nil) } }
        func string(_ t: TSWP_StringAttributeTable) -> [Entry] { t.entries.map { Entry(index: $0.characterIndex, object: nil) } }
        return [
            ("table_para_style", object(s.tableParaStyle)), ("table_para_data", paraData(s.tableParaData)),
            ("table_list_style", object(s.tableListStyle)), ("table_char_style", object(s.tableCharStyle)),
            ("table_attachment", object(s.tableAttachment)), ("table_smartfield", object(s.tableSmartfield)),
            ("table_layout_style", object(s.tableLayoutStyle)), ("table_para_starts", paraData(s.tableParaStarts)),
            ("table_bookmark", object(s.tableBookmark)), ("table_footnote", object(s.tableFootnote)),
            ("table_section", object(s.tableSection)), ("table_rubyfield", object(s.tableRubyfield)),
            ("table_language", string(s.tableLanguage)), ("table_dictation", string(s.tableDictation)),
            ("table_insertion", object(s.tableInsertion)), ("table_deletion", object(s.tableDeletion)),
            ("table_highlight", object(s.tableHighlight)), ("table_para_bidi", paraData(s.tableParaBidi)),
            ("table_tatechuyoko", object(s.tableTatechuyoko)), ("table_drop_cap_style", object(s.tableDropCapStyle)),
        ]
    }

    /// The storage's text length in UTF-16 code units.
    public static func textLength(_ storage: TSWP_StorageArchive) -> Int {
        storage.text.reduce(0) { $0 + $1.utf16.count }
    }

    public static func problems(in storage: TSWP_StorageArchive) -> [Problem] {
        let length = textLength(storage)
        var out = [Problem]()
        func check(_ table: String, _ indices: [UInt32]) {
            var previous: UInt32?
            for index in indices {
                if let p = previous, index <= p {
                    out.append(Problem(table: table, kind: .unsorted(previous: p, next: index), textLength: length))
                }
                if Int(index) > length {
                    out.append(Problem(table: table, kind: .pastEnd(index: index), textLength: length))
                }
                previous = index
            }
        }
        func object(_ table: String, _ t: TSWP_ObjectAttributeTable, _ has: Bool) {
            if has { check(table, t.entries.map(\.characterIndex)) }
        }
        func paraData(_ table: String, _ t: TSWP_ParaDataAttributeTable, _ has: Bool) {
            if has { check(table, t.entries.map(\.characterIndex)) }
        }
        func string(_ table: String, _ t: TSWP_StringAttributeTable, _ has: Bool) {
            if has { check(table, t.entries.map(\.characterIndex)) }
        }
        func overlapping(_ table: String, _ t: TSWP_OverlappingFieldAttributeTable, _ has: Bool) {
            guard has else { return }
            for entry in t.entries where Int(entry.range.location) + Int(entry.range.length) > length {
                out.append(Problem(table: table, kind: .rangePastEnd(location: entry.range.location, length: entry.range.length), textLength: length))
            }
        }
        let s = storage
        object("table_para_style", s.tableParaStyle, s.hasTableParaStyle)
        paraData("table_para_data", s.tableParaData, s.hasTableParaData)
        object("table_list_style", s.tableListStyle, s.hasTableListStyle)
        object("table_char_style", s.tableCharStyle, s.hasTableCharStyle)
        object("table_attachment", s.tableAttachment, s.hasTableAttachment)
        object("table_smartfield", s.tableSmartfield, s.hasTableSmartfield)
        object("table_layout_style", s.tableLayoutStyle, s.hasTableLayoutStyle)
        paraData("table_para_starts", s.tableParaStarts, s.hasTableParaStarts)
        object("table_bookmark", s.tableBookmark, s.hasTableBookmark)
        object("table_footnote", s.tableFootnote, s.hasTableFootnote)
        object("table_section", s.tableSection, s.hasTableSection)
        object("table_rubyfield", s.tableRubyfield, s.hasTableRubyfield)
        string("table_language", s.tableLanguage, s.hasTableLanguage)
        string("table_dictation", s.tableDictation, s.hasTableDictation)
        object("table_insertion", s.tableInsertion, s.hasTableInsertion)
        object("table_deletion", s.tableDeletion, s.hasTableDeletion)
        object("table_highlight", s.tableHighlight, s.hasTableHighlight)
        paraData("table_para_bidi", s.tableParaBidi, s.hasTableParaBidi)
        overlapping("table_overlapping_highlight", s.tableOverlappingHighlight, s.hasTableOverlappingHighlight)
        overlapping("table_pencil_annotation", s.tablePencilAnnotation, s.hasTablePencilAnnotation)
        object("table_tatechuyoko", s.tableTatechuyoko, s.hasTableTatechuyoko)
        object("table_drop_cap_style", s.tableDropCapStyle, s.hasTableDropCapStyle)
        return out
    }
}
