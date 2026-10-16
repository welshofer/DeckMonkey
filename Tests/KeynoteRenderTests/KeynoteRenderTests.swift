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

@Suite("Keynote render bounds")
struct KeynoteRenderBoundsTests {
    @Test("attribute lookups are binary searches that agree with a linear scan")
    func lookups() {
        let positions: [UInt32] = [0, 3, 3, 9, 20]
        for index in -1...25 {
            let linear = positions.last { Int($0) <= index }
            #expect(Canvas.entryAt(positions, index, { $0 }) == linear)
        }
        let starts = [0, 3, 9, 20]
        #expect(Canvas.next(starts, after: 3) == 9)
        #expect(Canvas.next(starts, after: 3, orEqual: true) == 3)
        #expect(Canvas.next(starts, after: 20) == nil)
    }
}

@Suite("Keynote render tables")
struct KeynoteRenderTableTests {
    @Test("a version-5 cell decodes its decimal, string id and formats; a short buffer is refused")
    func cell() {
        // 12.5 with number format 1 and currency format 3, as Keynote 15.4 stores it.
        var bytes: [UInt8] = [5, 2, 0, 0, 0, 0, 2, 0, 0x01, 0x70, 0, 0]
        bytes += [0x7D] + [UInt8](repeating: 0, count: 13) + [0x3E, 0x30]
        bytes += [1, 0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 0]
        let cell = StoredCell(bytes, at: 0)
        #expect(cell?.kind == .number && cell?.decimal == 12.5)
        #expect(cell?.formats[StoredCell.numberFormat] == 1 && cell?.formats[StoredCell.currencyFormat] == 3)
        #expect(StoredCell(Array(bytes.prefix(20)), at: 0) == nil)
        #expect(StoredCell(bytes, at: bytes.count - 4) == nil)
    }

    @Test("formats bound what a file asks for")
    func formats() {
        var f = TSK_FormatStructArchive()
        f.formatType = 259
        f.decimalPlaces = 4_000_000_000
        #expect(Canvas.formatNumber(1234.5, f).count < 40)
        #expect(Canvas.formatDate(.infinity, nil) == "")
        f.formatType = 256; f.decimalPlaces = 2; f.showThousandsSeparator = true
        #expect(Canvas.formatNumber(-1234567.891, f) == "-1,234,567.89")
    }
}
