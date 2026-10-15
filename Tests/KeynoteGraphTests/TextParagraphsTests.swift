import Foundation
import IWASchema
import Testing
@testable import KeynoteGraph

@Suite("Text paragraphs")
struct TextParagraphsTests {
    static let template = CorpusTests.repoRoot.appendingPathComponent("Corpus/templates/basic-black_wide.key")

    @Test("paragraphs at levels: \\n separators, one data and style entry per paragraph, U+2028 for line breaks, no table created", .enabled(if: FileManager.default.fileExists(atPath: template.path), "no Corpus/templates"))
    func levels() throws {
        var d = try KeynoteDocument.open(Self.template)
        let body = try #require(d.slideText(try d.slideList()[3].slide)?.body)           // Title & Bullets
        let before = try d.storageArchive(body)
        try d.setParagraphs(in: body, [.init("One"), .init("Two\nwrapped", level: 1), .init("Three", level: 2)])
        let s = try d.storageArchive(body)
        #expect(s.text == ["One\nTwo\u{2028}wrapped\nThree"])
        #expect(s.tableParaData.entries.map(\.characterIndex) == [0, 4, 16])
        #expect(s.tableParaData.entries.map(\.first) == [0, 1, 2])
        #expect(s.tableParaStyle.entries.map(\.characterIndex) == [0, 4, 16])
        #expect(s.tableParaStyle.entries[0].object.identifier == before.tableParaStyle.entries[0].object.identifier)
        #expect(s.tableParaStyle.entries.dropFirst().allSatisfy { !$0.hasObject })
        #expect(s.hasTableSmartfield == before.hasTableSmartfield && s.hasTableBookmark == before.hasTableBookmark)
        #expect(TextOffsets.problems(in: s).isEmpty)
        #expect(d.validate().filter { $0.severity == .error }.isEmpty)
    }

    @Test("refusals: no paragraphs, a level past 8")
    func refusals() throws {
        let s = TSWP_StorageArchive.with { $0.text = ["x"] }
        #expect(throws: TextParagraphs.Failure.noParagraphs) { try TextParagraphs.apply(s, paragraphs: []) }
        #expect(throws: TextParagraphs.Failure.levelOutOfRange(9)) { try TextParagraphs.apply(s, paragraphs: [.init("a", level: 9)]) }
    }
}
