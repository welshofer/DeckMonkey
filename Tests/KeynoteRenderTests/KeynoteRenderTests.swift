import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import IWASchema
import KeynoteGraph
import Testing
@testable import KeynoteRender

@Suite("Keynote render")
struct KeynoteRenderTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let decks: [URL] = ["Corpus/templates", "Corpus/features"].flatMap { dir -> [URL] in
        let url = root.appendingPathComponent(dir)
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "key" }.sorted { $0.path < $1.path }
    }

    @Test("numbers are deterministic: three decimals, no trailing zeros, no negative zero")
    func numbers() {
        #expect(SVG.n(1.0) == "1")
        #expect(SVG.n(0.1 + 0.2) == "0.3")
        #expect(SVG.n(-0.0001) == "0")
        #expect(SVG.n(1920.5) == "1920.5")
        #expect(SVG.n(Double.nan) == "0")
        #expect(SVG.escape("a<b & \"c\"\u{0}") == "a&lt;b &amp; &quot;c&quot;")
    }

    @Test("a bezier outline maps its own bounds onto the frame, not its natural size")
    func bezierBounds() {
        var path = TSP_Path()
        for (type, x, y) in [(TSP_Path.ElementType.moveTo, 0.0, 0.0), (.lineTo, 100, 0), (.lineTo, 100, 100), (.lineTo, 0, 100), (.closeSubpath, 0, 0), (.moveTo, 0, 0)] {
            var e = TSP_Path.Element()
            e.type = type
            if type != .closeSubpath { e.points = [TSP_Point.with { $0.x = Float(x); $0.y = Float(y) }] }
            path.elements.append(e)
        }
        let source = TSD_BezierPathSourceArchive.with {
            $0.path = path
            $0.naturalSize = TSP_Size.with { $0.width = 860; $0.height = 880 }
        }
        let outline = Paths.bezier(source)
        #expect(outline?.width == 100 && outline?.height == 100)
        #expect(outline?.d(sx: 8.6, sy: 8.8) == "M0 0L860 0L860 880L0 880Z")
    }

    /// AT-28: every slide of every template and feature deck renders, deterministically, to
    /// well-formed SVG; what is not drawn is reported by kind.
    @Test("AT-28: every corpus slide renders to well-formed SVG", .enabled(if: !decks.isEmpty, "no Corpus/templates or Corpus/features"))
    func corpus() throws {
        var slides = 0, kinds = [String: Int]()
        for deck in Self.decks {
            let document = try KeynoteDocument.open(deck)
            var renderer = KeynoteRenderer(document: document)
            renderer.imageHref = { name, _ in "data/" + name }
            for entry in try renderer.renderAll() {
                slides += 1
                let parser = XMLParser(data: Data(entry.rendered.svg.utf8))
                #expect(parser.parse(), "\(deck.lastPathComponent) slide \(entry.slide): \(parser.parserError.map { "\($0)" } ?? "")")
                #expect(renderer.render(slide: entry.slide) == entry.rendered, "\(deck.lastPathComponent) slide \(entry.slide) is not deterministic")
                for p in entry.rendered.problems { kinds[p, default: 0] += 1 }
            }
        }
        print("AT-28: \(slides) slides from \(Self.decks.count) decks; not drawn: \(kinds.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))")
        #expect(slides > 0)
    }
}
