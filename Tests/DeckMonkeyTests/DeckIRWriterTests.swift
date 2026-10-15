import Foundation
import Testing
@testable import DeckMonkey

/// Phase 4 without Keynote: every Corpus/ir fixture builds on every template that has the masters,
/// saves, reopens and validates; the template's sample slides are gone; every IR string is in the
/// deck. Rendering is Gate 4's job (Scripts/gate4/gate4.py).
@Suite("Deck IR writer")
struct DeckIRWriterTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Corpus/ir"), includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path } ?? []
    static let templates = ["basic-black_wide", "academy_wide", "minimalist-light_wide", "showcase_wide"]
        .map { root.appendingPathComponent("Corpus/templates/\($0).key") }.filter { FileManager.default.fileExists(atPath: $0.path) }

    @Test("every fixture builds on every full template, validates, and carries every IR string", .enabled(if: !fixtures.isEmpty && !templates.isEmpty, "no Corpus/ir or Corpus/templates"))
    func fixturesBuild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-ir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var built = 0
        for template in Self.templates {
            let base = try KeynoteDocument.open(template)
            for fixture in Self.fixtures {
                let ir = try JSONDecoder().decode(DeckIR.self, from: Data(contentsOf: fixture))
                let (doc, report) = try DeckIRWriter.build(ir, template: base)
                let out = dir.appendingPathComponent("\(built).key")
                try doc.save(to: out)
                let reread = try KeynoteDocument.open(out)
                #expect(reread.validate().filter { $0.severity == .error }.isEmpty, "\(fixture.lastPathComponent) on \(template.lastPathComponent)")
                #expect(try reread.slideList().count == ir.slides.count)
                #expect(report.slides.map(\.id) == ir.slides.map(\.id))
                var all = [String]()
                for slide in try reread.slideList() {
                    guard let t = reread.slideText(slide.slide) else { continue }
                    for id in [t.title, t.body, t.notes].compactMap({ $0 }) + t.textBoxes {
                        all.append(reread.storageText(id) ?? "")
                    }
                }
                let joined = all.joined(separator: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
                for s in ir.slides {
                    let b = s.body
                    let strings = [b?.subtitle, b?.value, b?.label, b?.quote, b?.attribution, b?.claim, b?.contact, b?.callToAction, b?.kicker].compactMap { $0 }
                        + (b?.items ?? []) + (b?.bullets ?? []).flatMap { [$0.text] + ($0.subBullets ?? []) } + (s.notes.map { [$0] } ?? [])
                    for string in strings where !string.isEmpty {
                        #expect(joined.contains(string), "\(fixture.lastPathComponent) \(s.id): “\(string)” missing on \(template.lastPathComponent)")
                    }
                }
                built += 1
            }
        }
        print("deck IR: \(built) builds (\(Self.fixtures.count) fixtures × \(Self.templates.count) templates) saved and validated")
    }

    @Test("an unsupported layout and an empty deck are refused with typed errors", .enabled(if: !templates.isEmpty, "no Corpus/templates"))
    func refusals() throws {
        let base = try KeynoteDocument.open(Self.templates[0])
        let timeline = DeckIR(meta: Meta(title: "x"), slides: [IRSlide(id: "a", layout: "timeline")])
        #expect(throws: DeckIRWriter.Failure.unsupportedLayout(slide: "a", layout: "timeline")) { try DeckIRWriter.build(timeline, template: base) }
        #expect(throws: DeckIRWriter.Failure.emptyDeck) { try DeckIRWriter.build(DeckIR(meta: Meta(title: "x"), slides: []), template: base) }
    }
}
