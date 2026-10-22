import Foundation
import Testing
@testable import DeckMonkey
import KeynoteGraph

/// The test pattern generator: its layout at 4K is the original's, it scales by a unit a 27th of
/// the height, everything is on the page, and it builds into a deck that validates.
@Suite("Test pattern")
struct TestPatternTests {
    @Test("at 3840 × 2160 the unit is 80 points and the layout is the original's")
    func fourK() throws {
        let scene = try TestPattern(width: 3840, height: 2160, titles: ["Keynote", "Keynote Next"], credit: "credit").scene()
        #expect(scene.slides.count == 2)
        let drawables = scene.slides[0].drawables
        // Seven bars 200 wide from x 1220, at y 360, 650 tall.
        let bars = drawables.filter { $0.width == 200 && $0.height == 650 }
        #expect(bars.map(\.x) == [1220, 1420, 1620, 1820, 2020, 2220, 2420])
        #expect(bars.allSatisfy { $0.y == 360 })
        // Grey steps on rows 22 and 23, from x 1480.
        let steps = drawables.filter { $0.width == 80 && $0.height == 80 }
        #expect(steps.count == 22 && Set(steps.map(\.y)) == [1760, 1840] && steps.map(\.x).min() == 1480)
        #expect(steps.compactMap { $0.text?.paragraphs.first?.text } == ["5", "10", "20", "30", "40", "50", "60", "70", "80", "90", "95"])
        // The heavy centre line and the labels.
        #expect(drawables.contains { $0.stroke?.width == 3 && $0.x == 840 && $0.angle == 270 })
        let texts = drawables.compactMap { $0.text?.paragraphs.first?.text }
        #expect(texts.contains("Keynote") && texts.contains("3840x2160") && texts.contains("credit"))
        #expect(scene.slides[1].drawables.contains { $0.text?.paragraphs.first?.text == "Keynote Next" })
    }

    @Test("every size keeps its drawables on the page", arguments: [(1920, 1080), (1280, 720), (1024, 768), (640, 480), (5120, 2880)])
    func onThePage(size: (Int, Int)) throws {
        let (w, h) = (Double(size.0), Double(size.1))
        let scene = try TestPattern(width: size.0, height: size.1).scene()
        #expect(scene.width == w && scene.height == h)
        for d in scene.slides[0].drawables where d.angle == 0 {
            #expect(d.x >= 0 && d.y >= 0 && d.x + d.width <= w + 1 && d.y + d.height <= h + 1, "\(d.x),\(d.y) \(d.width)x\(d.height)")
        }
    }

    @Test("too small, portrait, or without a title is refused")
    func refused() {
        #expect(throws: TestPattern.Failure.tooSmall(width: 200, height: 150)) { try TestPattern(width: 200, height: 150).scene() }
        #expect(throws: TestPattern.Failure.tooSmall(width: 1080, height: 1920)) { try TestPattern(width: 1080, height: 1920).scene() }
        #expect(throws: TestPattern.Failure.noTitles) { try TestPattern(width: 1920, height: 1080, titles: []).scene() }
    }

    @Test("it builds into a deck that validates", .enabled(if: FileManager.default.fileExists(atPath: SceneBuildTests.template.path), "no Corpus/templates"))
    func builds() throws {
        var document = try KeynoteDocument.open(SceneBuildTests.template)
        let report = try document.build(try TestPattern(width: 1280, height: 720).scene())
        #expect(report.slides.count == 1 && report.drawables > 500)
        let reopened = try KeynoteDocument.open(IWAPackage.openZip(document.serializedData()))
        #expect(reopened.validate().filter { $0.severity == .error }.isEmpty)
    }
}
