import Foundation
import IWASchema
import KeynoteGraph

/// One run of a text object's text: a stretch of one paragraph in one character look, with its
/// UTF-16 range in the storage (what `KeynoteDocument.replaceText(in:range:with:)` takes).
public struct SlideTextRun: Sendable, Equatable {
    public var paragraph: Int
    public var run: Int
    public var text: String
    public var range: Range<Int>
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var fontSize: Double
    /// `#rrggbb`.
    public var color: String
}

/// A drawable directly on a slide, as a host shows it for selection and editing.
public struct SlideDrawable: Sendable, Equatable {
    public enum Kind: String, Sendable { case placeholder, text, shape, image, movie, table, chart, group, line, other }
    public var id: UInt64
    public var kind: Kind
    /// "Title", "Body", "Text", "Shape", "Image", …
    public var name: String
    /// The unrotated frame in slide points.
    public var x: Double, y: Double, width: Double, height: Double
    /// Degrees, counter-clockwise, as Keynote stores it.
    public var angle: Double
    /// The text storage this drawable owns, if any.
    public var storage: UInt64?
    /// Its text by paragraph and run; an empty storage has one empty run to type into.
    public var runs: [SlideTextRun]
}

extension KeynoteRenderer {
    /// The drawables on `slide` in z-order, without hidden placeholders, with their text runs.
    public func drawables(onSlide slide: UInt64) -> [SlideDrawable] {
        var canvas = Canvas(document: document, fonts: fonts, imageHref: imageHref, size: slideSize)
        return canvas.drawables(onSlide: slide)
    }
}

extension Canvas {
    mutating func drawables(onSlide id: UInt64) -> [SlideDrawable] {
        guard let slide = document.decoded(KN_SlideArchive.self, id) else { return [] }
        let look = styles.slideLook(slide.hasStyle ? slide.style.identifier : nil)
        let hidden = hiddenPlaceholders(slide, look)
        var out = [SlideDrawable]()
        for ref in order(slide).prefix(2_000) where !hidden.contains(ref) {
            guard let t = type(of: ref) else { continue }
            var drawable: TSD_DrawableArchive?
            var kind = SlideDrawable.Kind.other, name = "Object", storage: UInt64?, path: TSD_PathSourceArchive?
            switch t {
            case Self.placeholderType:
                guard let p = document.decoded(KN_PlaceholderArchive.self, ref) else { continue }
                drawable = p.super.super.super
                path = p.super.super.hasPathsource ? p.super.super.pathsource : nil
                kind = .placeholder
                switch p.kind {
                case .kKindTitlePlaceholder: name = "Title"
                case .kKindBodyPlaceholder: name = "Body"
                case .kKindSlideNumberPlaceholder: name = "Slide Number"
                default: name = "Placeholder"
                }
                storage = p.super.hasOwnedStorage ? p.super.ownedStorage.identifier : nil
            case Self.shapeInfoType:
                guard let s = document.decoded(TSWP_ShapeInfoArchive.self, ref) else { continue }
                drawable = s.super.super
                path = s.super.hasPathsource ? s.super.pathsource : nil
                storage = s.hasOwnedStorage ? s.ownedStorage.identifier : nil
                kind = s.isTextBox ? .text : .shape
                name = s.isTextBox ? "Text" : "Shape"
            case Self.shapeType: drawable = document.decoded(TSD_ShapeArchive.self, ref)?.super; kind = .shape; name = "Shape"
            case Self.connectionLineType: drawable = document.decoded(TSD_ConnectionLineArchive.self, ref)?.super.super; kind = .line; name = "Line"
            case Self.imageType: drawable = document.decoded(TSD_ImageArchive.self, ref)?.super; kind = .image; name = "Image"
            case Self.movieType: drawable = document.decoded(TSD_MovieArchive.self, ref)?.super; kind = .movie; name = "Movie"
            case Self.groupType: drawable = document.decoded(TSD_GroupArchive.self, ref)?.super; kind = .group; name = "Group"
            case Self.tableType: drawable = document.decoded(TST_TableInfoArchive.self, ref)?.super; kind = .table; name = "Table"
            case Self.chartType: drawable = document.decoded(TSCH_ChartDrawableArchive.self, ref)?.super; kind = .chart; name = "Chart"
            default: continue
            }
            guard let d = drawable, d.hasGeometry else { continue }
            let g = d.geometry
            // A cropped image is shown, moved and resized by what shows: its mask's frame.
            var f = document.movableFrame(ref) ?? KeynoteDocument.Frame(x: Double(g.position.x), y: Double(g.position.y), width: Double(g.size.width), height: Double(g.size.height))
            // A self-sizing text box reports the frame its text takes, as drawn.
            if let storage, let sized = selfSizedFrame(g, storage: storage, look: styles.shapeLook(shapeStyle(ref)), path: path) {
                f = KeynoteDocument.Frame(x: sized.x, y: sized.y, width: sized.width, height: sized.height)
            }
            out.append(SlideDrawable(id: ref, kind: kind, name: name, x: f.x, y: f.y,
                                     width: f.width, height: f.height, angle: Double(g.angle),
                                     storage: storage, runs: storage.map { textRuns($0) } ?? []))
        }
        return out
    }

    /// The style of a shape or placeholder.
    func shapeStyle(_ id: UInt64) -> UInt64? {
        switch type(of: id) {
        case Self.placeholderType: return document.decoded(KN_PlaceholderArchive.self, id).flatMap { $0.super.super.hasStyle ? $0.super.super.style.identifier : nil }
        case Self.shapeInfoType: return document.decoded(TSWP_ShapeInfoArchive.self, id).flatMap { $0.super.hasStyle ? $0.super.style.identifier : nil }
        default: return nil
        }
    }

    /// `storage`'s text split into paragraphs and character-style runs, each with its look.
    mutating func textRuns(_ storage: UInt64, paragraphStyle fallback: UInt64? = nil) -> [SlideTextRun] {
        guard let archive = document.decoded(TSWP_StorageArchive.self, storage) else { return [] }
        let units = Array(archive.text.joined().utf16.prefix(Self.maximumTextUnits))
        let paraEntries = archive.tableParaStyle.entries.prefix(Self.maximumEntries).sorted { $0.characterIndex < $1.characterIndex }
        let charEntries = archive.tableCharStyle.entries.prefix(Self.maximumEntries).sorted { $0.characterIndex < $1.characterIndex }
        let charStarts = charEntries.map { Int($0.characterIndex) }
        var resolved = [(index: UInt32, style: UInt64?)](), running = fallback
        for e in paraEntries {
            if e.hasObject { running = e.object.identifier }
            resolved.append((e.characterIndex, running))
        }
        var looks = [String: CharLook]()
        func look(at i: Int) -> CharLook {
            let para = Self.entryAt(resolved, i, \.index).map { $0.style } ?? fallback
            let char = Self.entryAt(charEntries, i, \.characterIndex).flatMap { $0.hasObject ? $0.object.identifier : nil }
            let key = "\(para ?? 0):\(char ?? 0)"
            if let cached = looks[key] { return cached }
            let l = StyleResolver.charLook(styles.characterStyles(char).map(\.charProperties) + styles.paragraphStyles(para).map(\.charProperties))
            looks[key] = l
            return l
        }
        func run(_ p: Int, _ r: Int, _ range: Range<Int>) -> SlideTextRun {
            let l = look(at: range.lowerBound)
            return SlideTextRun(paragraph: p, run: r, text: String(decoding: units[range], as: UTF16.self), range: range,
                                bold: l.bold || l.fontName.contains("Bold") || l.fontName.contains("Heavy") || l.fontName.contains("Black"),
                                italic: l.italic || l.fontName.contains("Italic") || l.fontName.contains("Oblique"),
                                underline: l.underline, fontSize: l.size, color: l.color.hex)
        }
        var out = [SlideTextRun](), start = 0, paragraph = 0
        func flush(_ end: Int) {
            var r = 0, s = start
            // Binary search to the paragraph's first boundary, then walk only its own: linear
            // overall, however many paragraphs and style changes a storage holds.
            var lo = 0, hi = charStarts.count
            while lo < hi { let mid = (lo + hi) / 2; if charStarts[mid] <= start { lo = mid + 1 } else { hi = mid } }
            var k = lo
            while k < charStarts.count, charStarts[k] < end {
                let boundary = charStarts[k]
                if boundary > s { out.append(run(paragraph, r, s..<boundary)); r += 1 }
                s = boundary
                k += 1
            }
            out.append(run(paragraph, r, s..<end))
            paragraph += 1
        }
        for (i, u) in units.enumerated() where u == 0x0A || u == 0x0D || u == 0x2029 {
            flush(i); start = i + 1
        }
        flush(units.count)
        return out
    }
}
