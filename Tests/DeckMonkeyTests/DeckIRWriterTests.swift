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
        let parts = try ["drawables", "charts", "tables-parts"].map { Self.root.appendingPathComponent("Corpus/features/\($0).key") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }.map { try KeynoteDocument.open($0) }
        for template in Self.templates {
            let base = try KeynoteDocument.open(template)
            for fixture in Self.fixtures {
                let ir = try JSONDecoder().decode(DeckIR.self, from: Data(contentsOf: fixture))
                if ir.slides.contains(where: { $0.layout == "table" }), !FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("Corpus/features/tables-parts.key").path) {
                    continue                                       // needs tables-parts.key (make corpus)
                }
                let (doc, report) = try DeckIRWriter.build(ir, template: base, parts: parts)
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
                for (s, entry) in zip(ir.slides, try reread.slideList()) {
                    if let t = s.body?.table {
                        let models = reread.slideTables(entry.slide)
                        #expect(models.count == 1 && reread.tableSize(models[0])?.rows == t.rows.count + 1, "\(fixture.lastPathComponent) \(s.id): table")
                    }
                    if let c = s.body?.chart {
                        let grids = reread.slideDrawables(entry.slide).compactMap { reread.chartGrid($0) }
                        #expect(grids.count == 1 && grids[0].rows == c.series.map(\.name) && grids[0].columns == c.categories
                                && grids[0].values == c.series.map(\.values), "\(fixture.lastPathComponent) \(s.id): chart data")
                    }
                }
                for s in ir.slides {
                    let b = s.body
                    // Built step by step: as one expression, Swift 6.1 cannot type-check it in time.
                    let singles: [String?] = [b?.subtitle, b?.value, b?.label, b?.quote, b?.attribution, b?.claim, b?.contact, b?.callToAction, b?.kicker, b?.band]
                    var strings: [String] = singles.compactMap { $0 }
                    strings += b?.items ?? []
                    for bullet in b?.bullets ?? [] { strings.append(bullet.text); strings += bullet.subBullets ?? [] }
                    if let notes = s.notes { strings.append(notes) }
                    for stat in b?.stats ?? [] { strings += [stat.value, stat.label] }
                    for milestone in b?.milestones ?? [] { strings += [milestone.label, milestone.detail] }
                    for quadrant in b?.quadrants ?? [] { strings += [quadrant.heading, quadrant.detail] }
                    for item in b?.diagram?.items ?? [] { strings += item.components(separatedBy: " — ") }
                    for column in [b?.left, b?.right].compactMap({ $0 }) { strings.append(column.heading); strings += column.bullets }
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
        let chart = DeckIR(meta: Meta(title: "x"), slides: [IRSlide(id: "a", layout: "novel")])
        #expect(throws: DeckIRWriter.Failure.unsupportedLayout(slide: "a", layout: "novel")) { try DeckIRWriter.build(chart, template: base) }
        #expect(throws: DeckIRWriter.Failure.emptyDeck) { try DeckIRWriter.build(DeckIR(meta: Meta(title: "x"), slides: []), template: base) }
    }
}
