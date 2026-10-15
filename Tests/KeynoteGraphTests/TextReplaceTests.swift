import Foundation
import IWASchema
import SwiftProtobuf
import Testing
@testable import KeynoteGraph

/// Phase 1 rules on synthetic storages shaped like Keynote's (docs/spec.md §9, AT-14 to AT-17).
/// Character runs are start/end pairs, as Keynote writes them: `6→style` opens, a bare `10` closes.
@Suite("Text replace")
struct TextReplaceTests {
    typealias Entry = TSWP_ObjectAttributeTable.ObjectAttribute

    static func entry(_ index: UInt32, _ object: UInt64? = nil) -> Entry {
        var e = Entry()
        e.characterIndex = index
        if let object { e.object = TSP_Reference.with { $0.identifier = object } }
        return e
    }

    /// "Plain bold italic red" with bold (100) at 6..<10, italic (101) at 11..<17, red (102) at 18..<21.
    static func storage(_ text: String = "Plain bold italic red", hyperlinks: [(UInt32, UInt32, UInt64)] = []) -> TSWP_StorageArchive {
        var s = TSWP_StorageArchive()
        s.text = [text]
        s.tableParaStyle.entries = [entry(0, 1)]
        s.tableCharStyle.entries = [entry(0), entry(6, 100), entry(10), entry(11, 101), entry(17), entry(18, 102)]
        s.tableParaData.entries = [TSWP_ParaDataAttributeTable.ParaDataAttribute.with { $0.characterIndex = 0 }]
        if !hyperlinks.isEmpty {
            s.tableSmartfield.entries = [entry(0)] + hyperlinks.flatMap { [entry($0.0, $0.2), entry($0.1)] }
        }
        return s
    }

    static func runs(_ s: TSWP_StorageArchive) -> [String] {
        s.tableCharStyle.entries.map { "\($0.characterIndex)" + ($0.hasObject ? "→\($0.object.identifier)" : "") }
    }

    @Test("AT-14 shape: a same-length replace leaves every table byte-identical")
    func sameLength() throws {
        let s = Self.storage()
        let (out, report) = try TextReplace.apply(s, range: 6..<10, with: "BOLD")
        #expect(out.text == ["Plain BOLD italic red"])
        #expect(try out.tableCharStyle.serializedData() == s.tableCharStyle.serializedData())
        #expect(try out.tableParaStyle.serializedData() == s.tableParaStyle.serializedData())
        #expect(report == TextReplace.Report())
    }

    @Test("AT-15 shape: longer and shorter replaces shift what follows; tables stay sorted and in range")
    func lengthChanges() throws {
        let (longer, _) = try TextReplace.apply(Self.storage(), range: 6..<10, with: "emboldened")      // +6
        #expect(longer.text == ["Plain emboldened italic red"])
        #expect(Self.runs(longer) == ["0", "6→100", "16", "17→101", "23", "24→102"])
        #expect(TextOffsets.problems(in: longer).isEmpty)
        let (shorter, _) = try TextReplace.apply(Self.storage(), range: 11..<17, with: "it")           // -4
        #expect(shorter.text == ["Plain bold it red"])
        #expect(Self.runs(shorter) == ["0", "6→100", "10", "11→101", "13", "14→102"])
        #expect(TextOffsets.problems(in: shorter).isEmpty)
    }

    @Test("AT-16 shape: a replace spanning a style boundary takes the style at its start; what follows keeps its own")
    func spanningBoundary() throws {
        // "bold ital" (6..<15): starts in bold, ends inside italic. The italic run's tail ("ic")
        // must stay italic, so its start is re-anchored after the new text.
        let (out, report) = try TextReplace.apply(Self.storage(), range: 6..<15, with: "XYZ")
        #expect(out.text == ["Plain XYZic red"])
        #expect(Self.runs(out) == ["0", "6→100", "9→101", "11", "12→102"])
        #expect(report.collapsedEntries == 1)                // the bold run's end at 10
        #expect(TextOffsets.problems(in: out).isEmpty)
        // Ending exactly at a boundary: nothing to re-anchor, the entry there just shifts.
        let (exact, _) = try TextReplace.apply(Self.storage(), range: 6..<17, with: "B")
        #expect(Self.runs(exact) == ["0", "6→100", "7", "8→102"])
    }

    @Test("a deletion that makes two entries meet keeps the later one")
    func deletionCollision() throws {
        let (out, _) = try TextReplace.apply(Self.storage(), range: 6..<11, with: "")    // delete "bold "
        #expect(out.text == ["Plain italic red"])
        #expect(Self.runs(out) == ["0", "6→101", "12", "13→102"])
        #expect(TextOffsets.problems(in: out).isEmpty)
    }

    @Test("AT-17 shape: an overlapping hyperlink is removed and reported; others shift or stay")
    func hyperlinks() throws {
        let s = Self.storage(hyperlinks: [(6, 10, 900), (18, 21, 901)])
        let (out, report) = try TextReplace.apply(s, range: 8..<13, with: "--")
        #expect(report.removedFields == [900])
        #expect(out.tableSmartfield.entries.map(\.characterIndex) == [0, 15, 18])
        #expect(out.tableSmartfield.entries.compactMap { $0.hasObject ? $0.object.identifier : nil } == [901])
        // Inserting strictly inside a field removes it; inserting at its edge does not.
        #expect(try TextReplace.apply(s, range: 8..<8, with: "x").1.removedFields == [900])
        #expect(try TextReplace.apply(s, range: 6..<6, with: "x").1.removedFields.isEmpty)
        #expect(try TextReplace.apply(s, range: 10..<10, with: "x").1.removedFields.isEmpty)
    }

    @Test("only present tables are written: an edit never adds an empty one")
    func noNewTables() throws {
        let s = Self.storage()
        let (out, _) = try TextReplace.apply(s, range: 0..<5, with: "Plainer")
        #expect(!out.hasTableAttachment && !out.hasTableSmartfield && !out.hasTableListStyle && !out.hasTableDropCapStyle)
        let (same, _) = try TextReplace.apply(s, range: 0..<0, with: "")
        #expect(try same.serializedData(partial: true) == s.serializedData(partial: true))
    }

    @Test("offsets are UTF-16: an astral character is two units, and a range may not split it")
    func utf16() throws {
        var s = Self.storage("a😀b")                       // a, 😀 (2 units), b
        s.tableCharStyle.entries = [Self.entry(0), Self.entry(3, 100)]
        let (out, _) = try TextReplace.apply(s, range: 1..<3, with: "xyz")
        #expect(out.text == ["axyzb"])
        #expect(Self.runs(out) == ["0", "4→100"])
        #expect(throws: TextReplace.Failure.splitsSurrogatePair(at: 2)) { try TextReplace.apply(s, range: 2..<3, with: "") }
        #expect(TextReplace.occurrences(of: "b", in: "a😀b") == [3..<4])
    }

    @Test("refused in Phase 1: paragraph breaks, anchored objects, tracked changes, bad ranges")
    func refusals() {
        let s = Self.storage()
        #expect(throws: TextReplace.Failure.paragraphBreak) { try TextReplace.apply(s, range: 0..<5, with: "a\rb") }
        #expect(throws: TextReplace.Failure.paragraphBreak) { try TextReplace.apply(Self.storage("one\rtwo"), range: 2..<5, with: "x") }
        var attached = Self.storage("a\u{FFFC}b")
        attached.tableAttachment.entries = [Self.entry(1, 700)]
        #expect(throws: TextReplace.Failure.anchoredObjectInRange(table: "table_attachment", object: 700)) {
            try TextReplace.apply(attached, range: 0..<2, with: "x")
        }
        #expect(throws: Never.self) { try TextReplace.apply(attached, range: 2..<3, with: "c") }   // after it: fine
        var tracked = Self.storage()
        tracked.tableInsertion.entries = [Self.entry(0, 800)]
        #expect(throws: TextReplace.Failure.trackedChanges) { try TextReplace.apply(tracked, range: 0..<1, with: "x") }
        #expect(throws: TextReplace.Failure.rangeOutOfBounds(lower: 5, upper: 99, length: 21)) {
            try TextReplace.apply(s, range: 5..<99, with: "x")
        }
    }

    @Test("occurrences are left to right and non-overlapping")
    func occurrences() {
        #expect(TextReplace.occurrences(of: "aa", in: "aaaa") == [0..<2, 2..<4])
        #expect(TextReplace.occurrences(of: "x", in: "abc").isEmpty)
        #expect(TextReplace.occurrences(of: "", in: "abc").isEmpty)
    }
}
