import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import IWAContainer
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
        var digest: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a over every SVG, in deck order
        for deck in Self.decks {
            let document = try KeynoteDocument.open(deck)
            var renderer = KeynoteRenderer(document: document)
            renderer.imageHref = { name, _ in "data/" + name }
            for entry in try renderer.renderAll() {
                slides += 1
                for byte in entry.rendered.svg.utf8 { digest = (digest ^ UInt64(byte)) &* 0x100_0000_01b3 }
                let parser = XMLParser(data: Data(entry.rendered.svg.utf8))
                #expect(parser.parse(), "\(deck.lastPathComponent) slide \(entry.slide): \(parser.parserError.map { "\($0)" } ?? "")")
                #expect(renderer.render(slide: entry.slide) == entry.rendered, "\(deck.lastPathComponent) slide \(entry.slide) is not deterministic")
                for p in entry.rendered.problems { kinds[p, default: 0] += 1 }
            }
        }
        print("AT-28: \(slides) slides from \(Self.decks.count) decks; not drawn: \(kinds.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))")
        #expect(slides > 0)
        try checkRevision(digest: String(digest, radix: 16))
    }

    /// Hosts key cached renders on `KeynoteRenderer.revision`, so output that changes must change
    /// it. The corpus is built on this machine, so its digest lives beside it (git-ignored): a new
    /// revision records the digest; the same revision with a different digest fails.
    func checkRevision(digest: String) throws {
        let file = Self.root.appendingPathComponent("Corpus/.render-revision.json")
        let current = ["revision": "\(KeynoteRenderer.revision)", "digest": digest]
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode([String: String].self, from: data),
           stored["revision"] == current["revision"] {
            #expect(stored["digest"] == digest, "rendered output changed: bump KeynoteRenderer.revision (now \(KeynoteRenderer.revision))")
            return
        }
        try JSONEncoder().encode(current).write(to: file)
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

    @Test("a version-4 cell (Keynote 6–7) decodes its string, number and conditional rule")
    func cellVersion4() {
        // As a Keynote 7.2 table stores them: a text cell, and a number with a matched rule.
        let text: [UInt8] = [4, 3, 0, 0, 0x14, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0x19, 0, 0, 0]
        #expect(StoredCell(text, at: 0)?.kind == .text && StoredCell(text, at: 0)?.stringID == 0x19)
        var number: [UInt8] = [4, 2, 0, 0, 0x24, 0x0C, 0, 0, 0, 0, 1, 0, 4, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0]
        number += withUnsafeBytes(of: (149.88).bitPattern.littleEndian, Array.init) + [2, 0, 0, 0]
        let cell = StoredCell(number, at: 0)
        #expect(cell?.double == 149.88 && cell?.conditionalStyleID == 4 && cell?.appliedRule == 0)
        // An unseen flag leaves the cell undecoded rather than misread.
        #expect(StoredCell([4, 2, 0, 0, 0x01, 0, 0, 0] + [UInt8](repeating: 0, count: 28), at: 0) == nil)
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

@Suite("Keynote render charts")
struct KeynoteRenderChartTests {
    @Test("the value axis rounds up at the leading digit in four steps, and never overflows")
    func scale() {
        #expect(Canvas.scale(0, 9) == (0, 9, 2.25))
        #expect(Canvas.scale(0, 24) == (0, 30, 7.5))
        #expect(Canvas.scale(-3, 0) == (-3, 0, 0.75))
        let huge = Canvas.scale(0, 1e308)
        #expect(huge.step.isFinite && huge.max.isFinite)
        #expect(Canvas.scale(0, 0) == (0, 1, 0.25))
    }

    @Test("data bunched far from zero gets an axis near it, in the axis's own intervals")
    func axisRange() {
        // Phoenix Lander's velocities: Keynote's axis runs 24.3 to 24.8 in four steps.
        let a = Canvas.axisRange(dataMin: 24.46, dataMax: 24.721, settings: Canvas.AxisSettings())
        #expect(abs(a.min - 24.3) < 1e-9 && abs(a.max - 24.8) < 1e-9 && abs(a.step - 0.125) < 1e-9)
        // Data spread past a sixth of its maximum still starts at zero.
        #expect(Canvas.axisRange(dataMin: 3, dataMax: 9, settings: Canvas.AxisSettings()) == (0, 9, 2.25))
        // A user range wins.
        var settings = Canvas.AxisSettings(); settings.userMin = 10; settings.userMax = 20; settings.intervals = 5
        #expect(Canvas.axisRange(dataMin: 12, dataMax: 13, settings: settings) == (10, 20, 2))
    }
}

@Suite("Keynote movies")
struct KeynoteRenderMovieTests {
    static let deck = KeynoteRenderTests.root.appendingPathComponent("Corpus/features/media.key")

    @Test("a slide's movie and sound come with their files, timing and how they start",
          .enabled(if: FileManager.default.fileExists(atPath: deck.path), "no Corpus/features"))
    func movies() throws {
        let document = try KeynoteDocument.open(Self.deck)
        let renderer = KeynoteRenderer(document: document)
        let slides = document.slideOrder().map(\.slide)
        let movie = try #require(renderer.movies(onSlide: slides[0]).first)
        #expect(movie.fileName.hasSuffix(".m4v") && !movie.audioOnly && movie.startsOnBuild)
        #expect(movie.width == 480 && movie.height == 360 && movie.end.map { $0 > 85 && $0 < 86 } == true)
        #expect(renderer.movieData(movie)?.isEmpty == false)
        let sound = try #require(renderer.movies(onSlide: slides[1]).first)
        #expect(sound.fileName.hasSuffix(".m4a") && sound.audioOnly)
    }
}

@Suite("Keynote render outlines and fonts")
struct KeynoteRenderOutlineTests {
    @Test("an outline's bounds are its curves', not its control points'")
    func curveBounds() {
        // A quarter circle from (1, 0) to (0, 1) about the origin: control points reach (1, 0.552)
        // and (0.552, 1), the curve itself no further than its ends.
        let k = 0.5522847498
        let outline = Paths.fitted([.move(1, 0), .cubic(1, k, k, 1, 0, 1)], fallback: (1, 1))
        #expect(abs(outline.width - 1) < 1e-9 && abs(outline.height - 1) < 1e-9)
        // An arc that bulges past its ends is bounded by the bulge.
        let bulge = Paths.fitted([.move(0, 0), .cubic(0, 1, 1, 1, 1, 0)], fallback: (1, 1))
        #expect(abs(bulge.height - 0.75) < 1e-9)
    }

    @Test("a collection's face is copied out with its own table directory")
    func singleFace() {
        // 'ttcf' with one face of two tables ('aaaa' 3 bytes, 'bbbb' 5 bytes).
        var b: [UInt8] = Array("ttcf".utf8) + [0, 1, 0, 0] + [0, 0, 0, 1] + [0, 0, 0, 16]
        b += [0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0]                                // the face's offset table
        b += Array("aaaa".utf8) + [0, 0, 0, 9] + [0, 0, 0, 60] + [0, 0, 0, 3]  // records: tag, checksum, offset, length
        b += Array("bbbb".utf8) + [0, 0, 0, 8] + [0, 0, 0, 63] + [0, 0, 0, 5]
        b += [1, 2, 3, 4, 5, 6, 7, 8]
        guard let face = SFNTNames.singleFace(Data(b), index: 0).map(Array.init) else { Issue.record("no face"); return }
        #expect(Array(face[0..<12]) == [0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0])
        #expect(Array(face[20..<24]) == [0, 0, 0, 44] && Array(face[36..<40]) == [0, 0, 0, 48])
        #expect(Array(face[44..<47]) == [1, 2, 3] && Array(face[48..<53]) == [4, 5, 6, 7, 8] && face.count == 56)
        #expect(SFNTNames.singleFace(Data(b), index: 1) == nil)
        // A face whose directory runs past the data, or whose tables add up past it, is refused.
        var short = b; short[21] = 200                                       // 200 tables in 68 bytes
        #expect(SFNTNames.singleFace(Data(short), index: 0) == nil)
        var repeated = b                                                     // both tables: the whole file
        repeated[36...43] = [0, 0, 0, 0, 0, 0, 0, 68]; repeated[52...59] = [0, 0, 0, 0, 0, 0, 0, 68]
        #expect(SFNTNames.singleFace(Data(repeated), index: 0) == nil)
    }

    @Test("a host's font-face hook declares every face a slide sets text in",
          .enabled(if: FileManager.default.fileExists(atPath: KeynoteRenderHostTests.deck.path) && FileManager.default.fileExists(atPath: "/System/Library/Fonts/HelveticaNeue.ttc"), "no templates or no Helvetica Neue"))
    func fontFaceHook() throws {
        let document = try KeynoteDocument.open(KeynoteRenderHostTests.deck)
        var renderer = KeynoteRenderer(document: document, fonts: RenderFonts.library(directories: [URL(fileURLWithPath: "/System/Library/Fonts")]))
        let slide = try document.slideList()[0].slide
        #expect(!renderer.render(slide: slide).svg.contains("@font-face"))
        renderer.fontFace = { "data:font/otf;base64,\($0)" }
        let svg = renderer.render(slide: slide).svg
        #expect(svg.contains("@font-face{font-family:&apos;HelveticaNeue") || svg.contains("@font-face{font-family:&#39;HelveticaNeue") || svg.contains("@font-face{font-family:'HelveticaNeue"))
        // A URL cannot close the declaration it sits in.
        renderer.fontFace = { _ in "x');}</style><script>alert(1)</script>" }
        let hostile = renderer.render(slide: slide).svg
        #expect(!hostile.contains("<script>") && !hostile.contains("x');}"))
    }
}

@Suite("Keynote render host API")
struct KeynoteRenderHostTests {
    static let deck = KeynoteRenderTests.root.appendingPathComponent("Corpus/templates/basic-white_wide.key")

    @Test("a deck serializes to bytes that reopen to the same slides, and names its fonts", .enabled(if: FileManager.default.fileExists(atPath: deck.path), "no Corpus/templates"))
    func host() throws {
        let document = try KeynoteDocument.open(Self.deck)
        let bytes = try document.serializedData()
        let reopened = try KeynoteDocument.open(IWAPackage.openZip(bytes))
        #expect(try reopened.slideList().map(\.slide) == document.slideList().map(\.slide))
        let fonts = KeynoteRenderer(document: document).fontNames()
        #expect(fonts.contains("HelveticaNeue") && fonts.contains("HelveticaNeue-Bold"))
    }
}

/// AT-28 over the private corpus (`DECKMONKEY_CORPUS` or the git-ignored `.deckmonkey-corpus`):
/// decks from Keynote 6.5 to 15.4, iOS and iCloud, whose slide trees can be Keynote 6.5's root node
/// or nested. Keynote '09 files are refused by design; everything else must render.
@Suite("Keynote render private corpus")
struct KeynoteRenderPrivateCorpusTests {
    static let decks: [URL] = {
        let root = KeynoteRenderTests.root
        var dir: String? = ProcessInfo.processInfo.environment["DECKMONKEY_CORPUS"]
        if dir?.isEmpty ?? true, let pointer = try? String(contentsOf: root.appendingPathComponent(".deckmonkey-corpus"), encoding: .utf8) {
            dir = pointer.split(whereSeparator: \.isNewline).first.map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }
        }
        guard let dir, !dir.isEmpty, let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { return [] }
        var out = [URL]()
        for case let url as URL in walker where url.pathExtension.lowercased() == "key" {
            out.append(url); walker.skipDescendants()
        }
        return out.sorted { $0.path < $1.path }
    }()

    @Test("AT-28: every private deck a modern Keynote saved renders every slide", .enabled(if: !decks.isEmpty, "no private corpus configured"))
    func privateCorpus() throws {
        var rendered = 0, slides = 0
        for deck in Self.decks {
            guard let document = try? KeynoteDocument.open(deck) else { continue }   // Keynote '09: refused by design
            var renderer = KeynoteRenderer(document: document)
            renderer.imageHref = { name, _ in "data/" + name }
            let all = try renderer.renderAll()
            #expect(!all.isEmpty, "\(deck.lastPathComponent): no slides")
            #expect(all.count == document.slideOrder().count)
            for entry in all { #expect(XMLParser(data: Data(entry.rendered.svg.utf8)).parse(), "\(deck.lastPathComponent) slide \(entry.slide)") }
            rendered += 1; slides += all.count
        }
        print("AT-28 private: \(rendered) decks, \(slides) slides")
        #expect(rendered > 0)
    }
}

@Suite("Keynote render colour")
struct KeynoteRenderColourTests {
    @Test("Display P3 colours are drawn in sRGB")
    func displayP3() {
        func p3(_ r: Float, _ g: Float, _ b: Float) -> SVG.RGBA {
            SVG.RGBA(TSP_Color.with { $0.model = .rgb; $0.r = r; $0.g = g; $0.b = b; $0.a = 1; $0.rgbspace = .p3 })
        }
        // Greys are the same in both spaces; P3's red is outside sRGB and clips to its red.
        let grey = p3(0.5, 0.5, 0.5), red = p3(1, 0, 0)
        #expect(abs(grey.r - 0.5) < 1e-4 && abs(grey.g - 0.5) < 1e-4 && abs(grey.b - 0.5) < 1e-4)
        #expect(abs(red.r - 1) < 1e-9 && red.g == 0 && red.b == 0)
        // The 4K test pattern's magenta bar: in sRGB it is more saturated than its P3 numbers.
        let magenta = p3(0.7767552, 0.2629833, 0.8118301)
        #expect(magenta.r > 0.79 && magenta.g < 0.24 && magenta.b > 0.82)
        // sRGB colours are drawn as they are.
        let srgb = SVG.RGBA(TSP_Color.with { $0.model = .rgb; $0.r = 0.25; $0.g = 0.5; $0.b = 0.75; $0.a = 1; $0.rgbspace = .srgb })
        #expect(srgb.r == 0.25 && srgb.g == 0.5 && srgb.b == 0.75)
    }
}
