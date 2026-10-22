import Foundation
import IWASchema
import KeynoteGraph

extension KeynoteRenderer {
    /// The deck as a `Scene`: per slide, its master's drawables and then its own, each shape and
    /// text box as an outline with its resolved fill, stroke and text (fonts, sizes, colours as
    /// the styles resolve them). Pictures, movies, tables, charts and groups are not scenes yet and
    /// are listed in `skipped`.
    public func scene() -> (scene: Scene, skipped: [String]) {
        var canvas = Canvas(document: document, fonts: fonts, imageHref: imageHref, size: slideSize)
        var skipped = [String]()
        let slides = document.slideOrder().map { entry -> SceneSlide in
            guard let slide = document.decoded(KN_SlideArchive.self, entry.slide) else { return SceneSlide(drawables: []) }
            var drawables = [SceneDrawable]()
            if slide.hasTemplateSlide { drawables += canvas.sceneDrawables(of: slide.templateSlide.identifier, skipped: &skipped) }
            drawables += canvas.sceneDrawables(of: entry.slide, skipped: &skipped)
            return SceneSlide(drawables: drawables)
        }
        return (Scene(width: slideSize.width, height: slideSize.height, slides: slides), skipped)
    }
}

extension Canvas {
    mutating func sceneDrawables(of slideID: UInt64, skipped: inout [String]) -> [SceneDrawable] {
        guard let slide = document.decoded(KN_SlideArchive.self, slideID) else { return [] }
        let hidden = hiddenPlaceholders(slide, styles.slideLook(slide.hasStyle ? slide.style.identifier : nil))
        var out = [SceneDrawable]()
        for ref in order(slide).prefix(20_000) where !hidden.contains(ref) {
            let info: TSWP_ShapeInfoArchive?
            switch type(of: ref) {
            case Self.shapeInfoType: info = document.decoded(TSWP_ShapeInfoArchive.self, ref)
            case Self.placeholderType: info = document.decoded(KN_PlaceholderArchive.self, ref)?.super
            default:
                skipped.append("object \(ref) (type \(type(of: ref).map(String.init) ?? "?"))")
                continue
            }
            guard let info, let drawable = sceneDrawable(info) else { continue }
            out.append(drawable)
        }
        return out
    }

    mutating func sceneDrawable(_ info: TSWP_ShapeInfoArchive) -> SceneDrawable? {
        let shape = info.super
        guard shape.super.hasGeometry else { return nil }
        let g = shape.super.geometry
        // A dimension the text sizes is stored as 0; its laid-out size is the outline's.
        let outline = shape.hasPathsource ? Paths.outline(shape.pathsource) : nil
        let autoWidth = g.flags & 1 == 0, autoHeight = g.flags & 2 == 0
        let w = autoWidth ? outline?.width ?? 0 : Double(g.size.width), h = autoHeight ? outline?.height ?? 0 : Double(g.size.height)
        let look = styles.shapeLook(shape.hasStyle ? shape.style.identifier : nil)
        var path = [ScenePathElement]()
        if let outline {
            let sx = outline.width > 0 ? w / outline.width : 1, sy = outline.height > 0 ? h / outline.height : 1
            for c in outline.commands {
                switch c {
                case let .move(x, y): path.append(.init(.move, [x * sx, y * sy]))
                case let .line(x, y): path.append(.init(.line, [x * sx, y * sy]))
                case let .quad(a, b, x, y):
                    // As the cubic it equals (the scene keeps one curve kind).
                    let p0 = path.last.map { Array($0.points.suffix(2)) } ?? [0, 0]
                    let ax = a * sx, ay = b * sy, ex = x * sx, ey = y * sy
                    path.append(.init(.curve, [p0[0] + 2 * (ax - p0[0]) / 3, p0[1] + 2 * (ay - p0[1]) / 3, ex + 2 * (ax - ex) / 3, ey + 2 * (ay - ey) / 3, ex, ey]))
                case let .cubic(a, b, c2, d, x, y): path.append(.init(.curve, [a * sx, b * sy, c2 * sx, d * sy, x * sx, y * sy]))
                case .close: path.append(.init(.close))
                }
            }
        }
        var fill: SceneFill?
        if let f = look.fill {
            if f.hasColor { fill = SceneFill(color: Self.sceneColor(f.color)) }
            else if f.hasGradient {
                let gr = f.gradient
                fill = SceneFill(gradient: SceneGradient(radial: gr.type == .radial, stops: gr.stops.map { .init(color: Self.sceneColor($0.color), fraction: Double($0.fraction)) },
                                                         angle: Double(gr.hasAnglegradient ? gr.anglegradient.gradientangle : 0)))
            }
        }
        var stroke: SceneStroke?
        if let s = look.stroke, visible(s) { stroke = SceneStroke(color: Self.sceneColor(s.color), width: Double(s.width)) }
        var text: SceneText?
        let storageID = info.hasOwnedStorage ? info.ownedStorage.identifier : info.hasDeprecatedStorage ? info.deprecatedStorage.identifier : nil
        if let storageID, let storage = document.decoded(TSWP_StorageArchive.self, storageID), !storage.text.joined().isEmpty {
            text = sceneText(storage, look: look)
        }
        return SceneDrawable(x: Double(g.position.x), y: Double(g.position.y), width: w, height: h, angle: Double(g.angle),
                             path: path, fill: fill, stroke: stroke, text: text, textBox: info.isTextBox, flipped: g.flags & 4 != 0, autoWidth: autoWidth, autoHeight: autoHeight)
    }

    func sceneText(_ storage: TSWP_StorageArchive, look: StyleResolver.ShapeLook) -> SceneText {
        let units = Array(storage.text.joined().utf16)
        var paragraphs = [SceneParagraph]()
        var start = 0
        let paraEntries = storage.tableParaStyle.entries.sorted { $0.characterIndex < $1.characterIndex }
        let attachments = Dictionary(storage.tableAttachment.entries.map { (Int($0.characterIndex), $0.hasObject ? $0.object.identifier : 0) }, uniquingKeysWith: { a, _ in a })
        var running = look.paragraphStyle
        func styleAt(_ index: Int) -> UInt64? {
            var style = look.paragraphStyle
            for e in paraEntries where Int(e.characterIndex) <= index { if e.hasObject { style = e.object.identifier } }
            return style
        }
        for i in 0...units.count where i == units.count || units[i] == 0x0A || units[i] == 0x2029 {
            let range = start..<i
            running = styleAt(start)
            let para = styles.paraLook(running)
            // Character style at the paragraph's start, over the paragraph style.
            var char = para.char
            if let entry = storage.tableCharStyle.entries.last(where: { Int($0.characterIndex) <= start }), entry.hasObject {
                char = StyleResolver.charLook(styles.characterStyles(entry.object.identifier).map(\.charProperties) + styles.paragraphStyles(running).map(\.charProperties))
            }
            let slideNumber = range.contains { attachments[$0].map { [Self.slideNumberAttachmentType, 2043].contains(type(of: $0) ?? 0) } ?? false }
            let text = String(decoding: units[range].filter { $0 != 0xFFFC }, as: UTF16.self)
            let alignment: SceneText.Alignment
            switch para.alignment {
            case .tatvalue0: alignment = .left
            case .tatvalue1: alignment = .right
            case .tatvalue2: alignment = .center
            case .tatvalue3: alignment = .justified
            default: alignment = .natural
            }
            paragraphs.append(SceneParagraph(text: text, font: char.fontName, size: char.size, color: char.archivedColor.map(Self.sceneColor) ?? Self.hex(char.color), alignment: alignment, slideNumber: slideNumber))
            start = i + 1
        }
        let valign: SceneText.VerticalAlignment = look.verticalAlignment == .kFrameAlignMiddle ? .middle : look.verticalAlignment == .kFrameAlignBottom ? .bottom : .top
        return SceneText(paragraphs: paragraphs, verticalAlignment: valign, padding: [look.padding.left, look.padding.top, look.padding.right, look.padding.bottom])
    }

    /// An RGB colour exactly as archived, in CSS's `color()` syntax (`srgb` or `display-p3`,
    /// alpha after a slash when not 1); other models as the `#rrggbb[aa]` they draw as.
    static func sceneColor(_ c: TSP_Color) -> String {
        guard c.model == .rgb else { return hex(SVG.RGBA(c)) }
        let space = c.hasRgbspace && c.rgbspace == .p3 ? "display-p3" : "srgb"
        func number(_ v: Float) -> String { v == v.rounded() ? String(Int(v)) : "\(v)" }
        let alpha = !c.hasA || c.a == 1 ? "" : " / " + number(c.a)
        return "color(\(space) \(number(c.r)) \(number(c.g)) \(number(c.b))\(alpha))"
    }

    static func hex(_ c: SVG.RGBA) -> String {
        func b(_ v: Double) -> String { String(format: "%02x", Int((max(0, min(1, v)) * 255).rounded())) }
        return "#" + b(c.r) + b(c.g) + b(c.b) + (c.a < 0.9995 ? b(c.a) : "")
    }
}
