import Foundation
import Rostrum
import Testing
@testable import DeckMonkey

@Suite("Keynote Interchange integration")
struct InterchangeTests {
    private let main = """
    { "slides": [{"identifier":"one","note":{"string":"Before"},
      "vendor":{"huge":9007199254740993123456789,"precise":1.23000000000000000000000001e+7}}],
      "unknown":{"enabled":true} }
    """

    private func archive(main: String, optionalEntries: Bool = true, resource: Data? = Data([0, 1, 255])) throws -> Data {
        var writer = ZipWriter()
        writer.addFile(name: "main.json", data: Data(main.utf8))
        if optionalEntries {
            writer.addFile(name: "manifest.json", data: Data("{ \"package_version\":\"1.0\", \"vendor\":true }\n".utf8))
            writer.addFile(name: "presets.json", data: Data(" [ ] \n".utf8))
        }
        if let resource { writer.addFile(name: "Data/opaque.bin", data: resource) }
        writer.addFile(name: "vendor/metadata", data: Data([4, 3, 2, 1]))
        return try writer.finalize()
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-keyx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("file API preserves original entry bytes and edits through the shared model")
    func fileRoundTripAndEdit() throws {
        try withDirectory { directory in
            let input = directory.appendingPathComponent("input.keyx")
            let output = directory.appendingPathComponent("output.keyx")
            try archive(main: main).write(to: input)
            let report = try DeckMonkey.roundTripInterchange(input, to: output)
            #expect(report.isIdentical)
            #expect(report.identical == ["Data/opaque.bin", "main.json", "manifest.json", "presets.json", "vendor/metadata"])

            var document = try DeckMonkey.openInterchange(input)
            let before = document
            try document.editSlide(at: 0) { $0.setNote(.value(KeyxText("After"))) }
            try document.save(to: output)
            let reopened = try DeckMonkey.openInterchange(output)
            #expect(try reopened.inspectSlide(at: 0).notes == "After")
            #expect(reopened.presentation["slides"]?.array?.first?["vendor"] == before.presentation["slides"]?.array?.first?["vendor"])
            #expect(reopened.presentation["unknown"] == before.presentation["unknown"])
            #expect(reopened.entryData(named: "Data/opaque.bin") == before.entryData(named: "Data/opaque.bin"))
            #expect(reopened.entryData(named: "manifest.json") == before.entryData(named: "manifest.json"))
            #expect(reopened.entryData(named: "presets.json") == before.entryData(named: "presets.json"))
            #expect(reopened.entryData(named: "vendor/metadata") == before.entryData(named: "vendor/metadata"))
            let mainData = try #require(reopened.entryData(named: "main.json"))
            let encoded = try #require(String(data: mainData, encoding: .utf8))
            #expect(encoded.contains("9007199254740993123456789"))
            #expect(encoded.contains("1.23000000000000000000000001e+7"))
            #expect(try document.data() == Data(contentsOf: output))
        }
    }

    @Test("optional default entries are reported, not called an identical round trip")
    func reportsAddedDefaults() throws {
        try withDirectory { directory in
            let input = directory.appendingPathComponent("input.keyx")
            let output = directory.appendingPathComponent("output.keyx")
            try archive(main: main, optionalEntries: false).write(to: input)
            let report = try DeckMonkey.roundTripInterchange(input, to: output)
            #expect(report.preservesOriginalEntries)
            #expect(!report.isIdentical)
            #expect(report.added == ["manifest.json", "presets.json"])
            #expect(report.identical == ["Data/opaque.bin", "main.json", "vendor/metadata"])
        }
    }

    @Test("comparison detects modified and missing payloads as well as added entries")
    func comparisonNegativeControl() throws {
        let before = try KeyxDocument(data: archive(main: main, optionalEntries: false))
        let after = try KeyxDocument(data: archive(main: main.replacingOccurrences(of: "Before", with: "Corrupted"), resource: nil))
        let report = InterchangeRoundTripReport(original: before, reopened: after)
        #expect(!report.preservesOriginalEntries)
        #expect(!report.isIdentical)
        #expect(report.changed == ["main.json"])
        #expect(report.removed == ["Data/opaque.bin"])
        #expect(report.added == ["manifest.json", "presets.json"])
        #expect(report.identical == ["vendor/metadata"])
    }

    @Test("re-exported authoring and preview APIs work without native or PPTX intermediate files")
    func authorInspectAndRender() throws {
        try withDirectory { directory in
            let ir = DeckIR(meta: Meta(title: "Interchange"), slides: [
                IRSlide(id: "intro", layout: "bullets", title: "Native interchange",
                        body: Body(bullets: [Bullet(text: "Keep these words")]), notes: "Presenter notes"),
                IRSlide(id: "data", layout: "chart", title: "Numeric data",
                        body: Body(chart: IRChart(kind: "line", categories: ["Q1", "Q2"],
                                                series: [IRSeries(name: "Revenue", values: [2, 5])]))),
            ])
            let authored = try KeyxAuthor.render(ir)
            let output = directory.appendingPathComponent("authored.keyx")
            try authored.document.save(to: output)
            let reopened = try DeckMonkey.openInterchange(output)
            #expect(reopened.archiveEntryNames == ["main.json", "manifest.json", "presets.json"])
            #expect(try reopened.inspectSlide(at: 0).texts.contains("Keep these words"))
            #expect(try reopened.inspectSlide(at: 1).charts.first?.values == [[2, 5]])
            #expect(authored.slideGroups["intro"]?.count == 1)
            #expect(!authored.warnings.isEmpty)
            let preview = try KeyxPreviewRenderer.render(reopened, slideAt: 0)
            #expect(preview.svg.contains("<svg"))
            #expect(preview.svg.contains("Keep "))
            #expect(!preview.warnings.isEmpty)
        }
    }

    @Test("format boundaries and invalid edits fail before replacing output")
    func refusesWrongFormatAndInvalidSave() throws {
        try withDirectory { directory in
            let input = directory.appendingPathComponent("input.keyx")
            let native = directory.appendingPathComponent("native.key")
            let output = directory.appendingPathComponent("protected.keyx")
            try archive(main: main).write(to: input)
            #expect(throws: KeynoteFormatError.nativeOperationOnInterchange(path: input.path)) {
                try DeckMonkey.open(input)
            }
            #expect(throws: KeynoteFormatError.expectedInterchange(path: native.path)) {
                try DeckMonkey.openInterchange(native)
            }
            #expect(throws: KeynoteFormatError.expectedInterchange(path: native.path)) {
                try DeckMonkey.roundTripInterchange(input, to: native)
            }
            #expect(!FileManager.default.fileExists(atPath: native.path))
            var document = try DeckMonkey.openInterchange(input)
            try document.editSlide(at: 0) { $0.setNote(.cleared) }
            let sentinel = Data("Do not overwrite".utf8)
            try sentinel.write(to: output)
            #expect(throws: KeyxError.self) { try document.save(to: output) }
            #expect(try Data(contentsOf: output) == sentinel)
        }
    }
}
