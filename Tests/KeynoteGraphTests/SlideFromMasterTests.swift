import Foundation
import IWAContainer
import IWASchema
import Testing
@testable import KeynoteGraph

/// New slides on masters. Keynote's own New Slide is the oracle (Scripts/gate1/newslide.py); these
/// check every template: one new slide per master validates, reopens, points at its master, and
/// starts with empty placeholders.
@Suite("Slide from master")
struct SlideFromMasterTests {
    static let templates: [URL] = ((try? FileManager.default.contentsOfDirectory(at: CorpusTests.repoRoot.appendingPathComponent("Corpus/templates"), includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "key" }.sorted { $0.path < $1.path }

    @Test("every master of every template gives a new slide that validates and reopens", .enabled(if: !templates.isEmpty, "no Corpus/templates"))
    func everyMaster() throws {
        var added = 0
        for template in Self.templates {
            var document = try KeynoteDocument.open(template)
            let before = try document.slideList().count
            var made = [(UInt64, UInt64)]()
            for master in document.masters() {
                let report = try document.addSlide(fromMaster: master.id)
                made.append((report.slide, master.id))
            }
            let reopened = try KeynoteDocument.open(IWAPackage.openZip(document.serializedData()))
            #expect(try reopened.slideList().count == before + made.count, "\(template.lastPathComponent)")
            #expect(reopened.validate().filter { $0.severity == .error }.isEmpty, "\(template.lastPathComponent)")
            for (slide, master) in made {
                let archive = try #require(reopened.decoded(KN_SlideArchive.self, slide))
                #expect(archive.templateSlide.identifier == master && !archive.hasName && !archive.hasClassicStylesheetRecord)
                let text = reopened.slideText(slide)
                for storage in [text?.title, text?.body].compactMap({ $0 }) {
                    #expect(reopened.storageText(storage)?.isEmpty ?? true, "\(template.lastPathComponent) slide \(slide)")
                }
            }
            added += made.count
        }
        print("slide from master: \(added) slides on \(Self.templates.count) templates")
    }

    @Test("a master of another deck and an out-of-range position are refused", .enabled(if: !templates.isEmpty, "no Corpus/templates"))
    func refusals() throws {
        var document = try KeynoteDocument.open(Self.templates[0])
        let slide = try document.slideList()[0].slide
        #expect(throws: KeynoteDocument.NewSlideFailure.notAMaster(slide)) { try document.addSlide(fromMaster: slide) }
        let master = try #require(document.masters().first)
        #expect(throws: (any Error).self) { try document.addSlide(fromMaster: master.id, at: 10_000) }
    }
}
