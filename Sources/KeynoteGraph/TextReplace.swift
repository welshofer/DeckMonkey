import Foundation
import IWASchema
import SwiftProtobuf

/// Phase 1 text replace on one `TSWP.StorageArchive` (docs/spec.md §9).
///
/// iWork indexes text in UTF-16 code units; every offset here is one. The storage's single text
/// string (every corpus storage has exactly one) is edited, and every character-indexed table is
/// remapped through the edit:
/// - entries before the range stay; the entry in force at the range start carries the new text
///   (single-run semantics: the new text takes the style in force at the first replaced character);
/// - entries strictly inside the range are dropped, except that the one in force at the range end
///   is re-anchored just after the new text, so the text after the edit keeps its own style;
/// - entries at or after the range end shift by the length change; when two land on one index (a
///   deletion), the later one wins.
/// Fields (hyperlinks and other smart fields, bookmarks, ruby, tate-chu-yoko, highlights) that
/// overlap the range are removed and reported; their text stays as plain text.
///
/// Out of Phase 1 scope, refused rather than guessed: a paragraph break in the range or the new
/// text, an attachment or footnote anchored inside the range, tracked changes, and more than one
/// text string.
public enum TextReplace {
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case notAStorage(UInt64)
        case multipleTextStrings(Int)
        case rangeOutOfBounds(lower: Int, upper: Int, length: Int)
        case splitsSurrogatePair(at: Int)
        case paragraphBreak
        case anchoredObjectInRange(table: String, object: UInt64?)
        case trackedChanges

        public var description: String {
            switch self {
            case .notAStorage(let id): return "object \(id) is not a TSWP.StorageArchive"
            case .multipleTextStrings(let n): return "the storage holds \(n) text strings; Phase 1 edits one"
            case .rangeOutOfBounds(let l, let u, let n): return "range \(l)..<\(u) is outside the text (length \(n))"
            case .splitsSurrogatePair(let at): return "UTF-16 offset \(at) splits a surrogate pair"
            case .paragraphBreak: return "the range or the new text contains a paragraph break (Phase 1 replaces within a paragraph)"
            case .anchoredObjectInRange(let table, let object):
                return "the range covers an object anchored in the text (\(table)\(object.map { " → \($0)" } ?? "")); Phase 1 does not remove inline objects"
            case .trackedChanges: return "the storage has tracked changes; Phase 1 does not edit them"
            }
        }
    }

    public struct Report: Equatable, Sendable {
        /// Fields removed because they overlapped the range: hyperlinks and other smart fields
        /// (`table_smartfield`), bookmarks, ruby, tate-chu-yoko, highlights.
        public var removedFields: [UInt64] = []
        /// Run boundaries inside the range that collapsed into the run in force at its start.
        public var collapsedEntries = 0
    }

    static let breaks: Set<UInt16> = [0x0A, 0x0D, 0x2028, 0x2029, 0x0C, 0x0B]

    /// Replaces UTF-16 `range` of `storage`'s text with `replacement`.
    public static func apply(_ storage: TSWP_StorageArchive, range: Range<Int>, with replacement: String) throws(Failure) -> (TSWP_StorageArchive, Report) {
        guard storage.text.count <= 1 else { throw .multipleTextStrings(storage.text.count) }
        let old = Array((storage.text.first ?? "").utf16)
        let new = Array(replacement.utf16)
        let a = range.lowerBound, b = range.upperBound, n = new.count, length = old.count
        guard a >= 0, b <= length else { throw .rangeOutOfBounds(lower: a, upper: b, length: length) }
        for edge in [a, b] where edge > 0 && edge < length && UTF16.isTrailSurrogate(old[edge]) && UTF16.isLeadSurrogate(old[edge - 1]) {
            throw .splitsSurrogatePair(at: edge)
        }
        if old[a..<b].contains(where: breaks.contains) || new.contains(where: breaks.contains) { throw .paragraphBreak }
        guard storage.tableInsertion.entries.isEmpty, storage.tableDeletion.entries.isEmpty else { throw .trackedChanges }

        var s = storage
        var report = Report()

        // Anchored objects: one character each. Inside the range they would be deleted with it.
        func anchored(_ name: String, _ t: TSWP_ObjectAttributeTable) throws(Failure) {
            if let e = t.entries.first(where: { Int($0.characterIndex) >= a && Int($0.characterIndex) < b && $0.hasObject }) {
                throw .anchoredObjectInRange(table: name, object: e.object.identifier)
            }
        }
        try anchored("table_attachment", s.tableAttachment)
        try anchored("table_footnote", s.tableFootnote)

        // Fields: an entry with an object opens a field that runs to the next entry (or the end).
        func removeOverlappingFields(_ t: inout TSWP_ObjectAttributeTable) {
            for (i, e) in t.entries.enumerated() where e.hasObject {
                let start = Int(e.characterIndex)
                let end = i + 1 < t.entries.count ? Int(t.entries[i + 1].characterIndex) : length
                let overlaps = a == b ? (start < a && a < end) : (start < b && a < end)
                if overlaps {
                    report.removedFields.append(e.object.identifier)
                    t.entries[i].clearObject()
                }
            }
        }
        // Only present tables are touched: assigning to an absent sub-message creates it, and
        // Keynote "upgrades" a storage that carries empty tables it never wrote, on every read.
        if s.hasTableSmartfield { removeOverlappingFields(&s.tableSmartfield) }
        if s.hasTableBookmark { removeOverlappingFields(&s.tableBookmark) }
        if s.hasTableRubyfield { removeOverlappingFields(&s.tableRubyfield) }
        if s.hasTableTatechuyoko { removeOverlappingFields(&s.tableTatechuyoko) }
        if s.hasTableHighlight { removeOverlappingFields(&s.tableHighlight) }

        // The remap every character-indexed table goes through.
        func remap<E>(_ entries: [E], index: (E) -> UInt32, set: (inout E, UInt32) -> Void) -> [E] {
            let atEnd = b < length
            // The entry in force at b, if it starts strictly inside the range: re-anchor it.
            let carry = entries.last(where: { Int(index($0)) > a && Int(index($0)) < b })
            let hasEntryAtB = entries.contains { Int(index($0)) == b }
            var out = [E]()
            for e in entries {
                let i = Int(index(e))
                if i <= a {
                    out.append(e)
                } else if i < b {
                    report.collapsedEntries += 1
                } else {
                    var moved = e
                    set(&moved, UInt32(i + n - (b - a)))
                    out.append(moved)
                }
            }
            if atEnd, !hasEntryAtB, var c = carry {
                report.collapsedEntries -= 1
                set(&c, UInt32(a + n))
                let at = out.firstIndex(where: { Int(index($0)) > a + n }) ?? out.endIndex
                out.insert(c, at: at)
            }
            // Equal indexes (a deletion, or a carry landing on the start entry): the later one wins.
            var deduped = [E]()
            for e in out {
                if let last = deduped.last, index(last) == index(e) { deduped.removeLast() }
                deduped.append(e)
            }
            return deduped
        }
        func object(_ t: inout TSWP_ObjectAttributeTable) {
            t.entries = remap(t.entries, index: \.characterIndex, set: { $0.characterIndex = $1 })
        }
        func paraData(_ t: inout TSWP_ParaDataAttributeTable) {
            t.entries = remap(t.entries, index: \.characterIndex, set: { $0.characterIndex = $1 })
        }
        func string(_ t: inout TSWP_StringAttributeTable) {
            t.entries = remap(t.entries, index: \.characterIndex, set: { $0.characterIndex = $1 })
        }
        func overlapping(_ t: inout TSWP_OverlappingFieldAttributeTable) {
            var kept = [TSWP_OverlappingFieldAttributeTable.OverlappingFieldAttribute]()
            for var e in t.entries {
                let start = Int(e.range.location), end = start + Int(e.range.length)
                if start < b && a < end || (a == b && start < a && a < end) {
                    report.removedFields.append(e.field.identifier)
                    continue
                }
                if start >= b { e.range.location = UInt32(start + n - (b - a)) }
                kept.append(e)
            }
            t.entries = kept
        }

        if s.hasTableParaStyle { object(&s.tableParaStyle) }
        if s.hasTableParaData { paraData(&s.tableParaData) }
        if s.hasTableListStyle { object(&s.tableListStyle) }
        if s.hasTableCharStyle { object(&s.tableCharStyle) }
        if s.hasTableAttachment { object(&s.tableAttachment) }
        if s.hasTableSmartfield { object(&s.tableSmartfield) }
        if s.hasTableLayoutStyle { object(&s.tableLayoutStyle) }
        if s.hasTableParaStarts { paraData(&s.tableParaStarts) }
        if s.hasTableBookmark { object(&s.tableBookmark) }
        if s.hasTableFootnote { object(&s.tableFootnote) }
        if s.hasTableSection { object(&s.tableSection) }
        if s.hasTableRubyfield { object(&s.tableRubyfield) }
        if s.hasTableLanguage { string(&s.tableLanguage) }
        if s.hasTableDictation { string(&s.tableDictation) }
        if s.hasTableHighlight { object(&s.tableHighlight) }
        if s.hasTableParaBidi { paraData(&s.tableParaBidi) }
        if s.hasTableOverlappingHighlight { overlapping(&s.tableOverlappingHighlight) }
        if s.hasTablePencilAnnotation { overlapping(&s.tablePencilAnnotation) }
        if s.hasTableTatechuyoko { object(&s.tableTatechuyoko) }
        if s.hasTableDropCapStyle { object(&s.tableDropCapStyle) }

        // A removed field leaves a null entry; drop nulls that only repeat the one before.
        func collapseNulls(_ t: inout TSWP_ObjectAttributeTable) {
            var entries = [TSWP_ObjectAttributeTable.ObjectAttribute]()
            for e in t.entries {
                if !e.hasObject, let last = entries.last, !last.hasObject { continue }
                entries.append(e)
            }
            t.entries = entries
        }
        if s.hasTableSmartfield { collapseNulls(&s.tableSmartfield) }
        if s.hasTableBookmark { collapseNulls(&s.tableBookmark) }
        if s.hasTableRubyfield { collapseNulls(&s.tableRubyfield) }
        if s.hasTableTatechuyoko { collapseNulls(&s.tableTatechuyoko) }
        if s.hasTableHighlight { collapseNulls(&s.tableHighlight) }

        s.text = [String(decoding: old[..<a] + new + old[b...], as: UTF16.self)]
        return (s, report)
    }

    /// Every occurrence of `needle` in `text`, as UTF-16 ranges, left to right, non-overlapping.
    public static func occurrences(of needle: String, in text: String) -> [Range<Int>] {
        let hay = Array(text.utf16), pin = Array(needle.utf16)
        guard !pin.isEmpty, pin.count <= hay.count else { return [] }
        var out = [Range<Int>](), i = 0
        while i + pin.count <= hay.count {
            if hay[i..<(i + pin.count)].elementsEqual(pin) {
                out.append(i..<(i + pin.count))
                i += pin.count
            } else {
                i += 1
            }
        }
        return out
    }
}
