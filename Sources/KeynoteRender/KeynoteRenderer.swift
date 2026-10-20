import Foundation
import IWASchema
import KeynoteGraph
import Rostrum

/// One slide drawn as SVG, in slide points (the viewBox is the show's size).
public struct RenderedSlide: Sendable, Equatable {
    public var svg: String
    public var width: Double
    public var height: Double
    /// What the renderer could not draw, by kind ("table", "shadow"), sorted and without repeats.
    /// Nothing is dropped silently (AT-28).
    public var problems: [String]
}

/// Track R (docs/spec.md §12): a read-only renderer that draws a Keynote slide as SVG, so a viewer
/// can show a `.key` without Keynote. It reads the graph and writes nothing back.
///
/// Fonts come from the caller as `RenderFonts` (faces by PostScript name, measured with Rostrum's
/// `FontMetrics`); text in a face it lacks is laid out with estimated metrics and reported.
public struct KeynoteRenderer {
    /// Changes whenever the SVG drawn for the same file changes, so hosts that cache rendered
    /// slides (Duo's thumbnails) can key on it. AT-28 checks it against the corpus's output.
    public static let revision = 9

    public let document: KeynoteDocument
    public let fonts: RenderFonts?
    /// How an image file becomes an `href`: by default a `data:` URI of the file's bytes.
    public var imageHref: (_ fileName: String, _ bytes: Data) -> String = KeynoteRenderer.dataURI
    /// Where a face the slide uses can be loaded from (a `data:` URL of its font file), to be
    /// declared with `@font-face` in the SVG: a host whose drawing process cannot see the fonts
    /// it measured with (a downloaded font on iOS) embeds them. Nil (the default) embeds none.
    public var fontFace: ((_ postScriptName: String) -> String?)?

    public init(document: KeynoteDocument, fonts: RenderFonts? = nil) {
        self.document = document
        self.fonts = fonts
    }

    /// The show's slide size in points (1920 × 1080 for a wide deck).
    public var slideSize: (width: Double, height: Double) {
        guard let id = document.store.identifiers.first(where: { document.store.record(for: $0)?.info.messageInfos.first?.type == Self.showType }),
              let show = document.decoded(KN_ShowArchive.self, id), show.hasSize else { return (1920, 1080) }
        return (Double(show.size.width), Double(show.size.height))
    }

    /// Every slide in show order with its PDF page (nil when skipped), drawn.
    public func renderAll() throws -> [(slide: UInt64, page: Int?, rendered: RenderedSlide)] {
        let pages = document.pageOfSlide
        return document.slideOrder().map { ($0.slide, pages[$0.slide], render(slide: $0.slide)) }
    }

    /// The PostScript names of every face the deck's paragraph, character and list styles name,
    /// so a host can load just those into `RenderFonts`.
    public func fontNames() -> Set<String> {
        var names = Set<String>()
        for id in document.store.identifiers {
            switch document.store.record(for: id)?.info.messageInfos.first?.type {
            case 2021?: if let s = document.decoded(TSWP_CharacterStyleArchive.self, id), s.charProperties.hasFontName { names.insert(s.charProperties.fontName) }
            case 2022?: if let s = document.decoded(TSWP_ParagraphStyleArchive.self, id), s.charProperties.hasFontName { names.insert(s.charProperties.fontName) }
            case 2023?: if let s = document.decoded(TSWP_ListStyleArchive.self, id), s.hasFontName { names.insert(s.fontName) }
            default: break
            }
        }
        return names.filter { !$0.isEmpty }
    }

    public func render(slide: UInt64) -> RenderedSlide {
        let size = slideSize
        var canvas = Canvas(document: document, fonts: fonts, imageHref: imageHref, size: size)
        canvas.slideNumber = document.pageOfSlide[slide]
        canvas.drawSlide(slide)
        if let fontFace {
            let faces = canvas.usedFaces.sorted().compactMap { name in fontFace(name).map { (name, $0) } }
            if !faces.isEmpty {
                _ = canvas.defs.add { _ in "<style>" + faces.map { "@font-face{font-family:'\($0.0)';src:url(\(SVG.escape($0.1)))}" }.joined() + "</style>" }
            }
        }
        return canvas.finish()
    }

    public static func dataURI(_ fileName: String, _ bytes: Data) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "gif": mime = "image/gif"
        case "tif", "tiff": mime = "image/tiff"
        case "heic": mime = "image/heic"
        case "pdf": mime = "application/pdf"
        case "svg": mime = "image/svg+xml"
        default: mime = "image/jpeg"
        }
        return "data:\(mime);base64," + bytes.base64EncodedString()
    }

    static let showType: UInt32 = 2
}

/// The state of drawing one slide.
struct Canvas {
    let document: KeynoteDocument
    let fonts: RenderFonts?
    let imageHref: (String, Data) -> String
    let size: (width: Double, height: Double)
    let styles: StyleResolver
    var defs = Definitions()
    var body = ""
    var problems = Set<String>()
    /// The PostScript names of the faces text was set in, for a host to embed.
    var usedFaces = Set<String>()
    var depth = 0
    /// Drawables still allowed on this slide: groups may list a child many times over, so nesting
    /// alone does not bound the work.
    var budget = 10_000
    /// Groups being drawn, so a group that contains itself stops.
    var active = Set<UInt64>()
    /// What a slide-number field shows: the slide's page in the export.
    var slideNumber: Int?
    /// The width and height the last laid-out text needed, padding included.
    var lastTextExtent = (width: 0.0, height: 0.0)
    /// The alignment of the last laid-out text's first line.
    var lastTextAlignment = TSWP_ParagraphStylePropertiesArchive.TextAlignmentType.tatvalue0

    init(document: KeynoteDocument, fonts: RenderFonts?, imageHref: @escaping (String, Data) -> String, size: (width: Double, height: Double)) {
        self.document = document
        self.fonts = fonts
        self.imageHref = imageHref
        self.size = size
        self.styles = StyleResolver(document: document)
    }

    func type(of id: UInt64) -> UInt32? { document.store.record(for: id)?.info.messageInfos.first?.type }

    mutating func finish() -> RenderedSlide {
        let w = SVG.n(size.width), h = SVG.n(size.height)
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" viewBox=\"0 0 \(w) \(h)\" width=\"\(w)\" height=\"\(h)\">"
            + defs.markup + "<clipPath id=\"slide\"><rect width=\"\(w)\" height=\"\(h)\"/></clipPath><g clip-path=\"url(#slide)\">"
            + body + "</g></svg>"
        return RenderedSlide(svg: svg, width: size.width, height: size.height, problems: problems.sorted())
    }

    // MARK: Slide

    mutating func drawSlide(_ id: UInt64) {
        guard let slide = document.decoded(KN_SlideArchive.self, id) else { problems.insert("slide"); return }
        let master = slide.hasTemplateSlide ? document.decoded(KN_SlideArchive.self, slide.templateSlide.identifier) : nil
        let look = styles.slideLook(slide.hasStyle ? slide.style.identifier : nil)

        // Background: white under everything, as Keynote's export starts from.
        body += "<rect width=\"\(SVG.n(size.width))\" height=\"\(SVG.n(size.height))\" fill=\"#ffffff\"/>"
        if let fill = look.fill {
            body += paintedRect(fill, x: 0, y: 0, w: size.width, h: size.height)
        }

        // The master's own objects. Objects a master tags for its slides (sage tags: "Media",
        // "Text") are copied onto each slide made from it, so the slide's copy is drawn instead;
        // placeholders are drawn from the slide's own.
        if let master {
            let tagged = Set(master.sageTagToInfoMap.map(\.info.identifier))
            for ref in order(master) where !tagged.contains(ref) && type(of: ref) != Self.placeholderType {
                drawDrawable(ref)
            }
        }
        let hidden = hiddenPlaceholders(slide, look)
        for ref in order(slide) where !hidden.contains(ref) {
            drawDrawable(ref)
        }
    }

    func order(_ slide: KN_SlideArchive) -> [UInt64] {
        (slide.drawablesZOrder.isEmpty ? slide.ownedDrawables : slide.drawablesZOrder).map(\.identifier)
    }

    func hiddenPlaceholders(_ slide: KN_SlideArchive, _ look: StyleResolver.SlideLook) -> Set<UInt64> {
        var hidden = Set<UInt64>()
        if !look.titleVisible, slide.hasTitlePlaceholder { hidden.insert(slide.titlePlaceholder.identifier) }
        if !look.bodyVisible, slide.hasBodyPlaceholder { hidden.insert(slide.bodyPlaceholder.identifier) }
        if !look.objectVisible, slide.hasObjectPlaceholder { hidden.insert(slide.objectPlaceholder.identifier) }
        if !look.slideNumberVisible, slide.hasSlideNumberPlaceholder { hidden.insert(slide.slideNumberPlaceholder.identifier) }
        return hidden
    }

    // MARK: Drawables

    mutating func drawDrawable(_ id: UInt64) {
        guard depth < 16 else { problems.insert("nesting"); return }
        guard budget > 0 else { problems.insert("drawables over budget"); return }
        guard !active.contains(id) else { problems.insert("group cycle"); return }
        budget -= 1
        depth += 1
        active.insert(id)
        defer { depth -= 1; active.remove(id) }
        switch type(of: id) {
        case Self.placeholderType:
            if let p = document.decoded(KN_PlaceholderArchive.self, id) { drawShapeInfo(p.super) }
        case Self.shapeInfoType:
            if let s = document.decoded(TSWP_ShapeInfoArchive.self, id) { drawShapeInfo(s) }
        case Self.shapeType:
            if let s = document.decoded(TSD_ShapeArchive.self, id) { drawShape(s, text: nil) }
        case Self.connectionLineType:
            if let c = document.decoded(TSD_ConnectionLineArchive.self, id) { drawShape(c.super, text: nil) }
        case Self.imageType:
            if let i = document.decoded(TSD_ImageArchive.self, id) { drawImage(i) }
        case Self.movieType:
            if let m = document.decoded(TSD_MovieArchive.self, id) { drawMovie(m) }
        case Self.groupType:
            if let g = document.decoded(TSD_GroupArchive.self, id) { drawGroup(g) }
        case Self.tableType:
            if let t = document.decoded(TST_TableInfoArchive.self, id) { drawTable(t) } else { problems.insert("table") }
        case Self.wpTableType:
            // A table that came from a word-processing document (pasted from Pages): an ordinary
            // table under a wrapper.
            if let t = document.decoded(TST_WPTableInfoArchive.self, id), t.hasSuper { drawTable(t.super) } else { problems.insert("table") }
        case Self.chartType:
            if let c = document.decoded(TSCH_ChartDrawableArchive.self, id) { drawChart(c) } else { problems.insert("chart") }
        case Self.equationType: problems.insert("equation")
        case let t?: problems.insert("drawable type \(t)")
        case nil: problems.insert("missing drawable")
        }
    }

    /// The SVG transform that puts a drawable's frame (origin top-left, unrotated size `w × h`)
    /// on the slide: rotation is about the frame's centre, Keynote's angle counter-clockwise.
    func transform(_ g: TSD_GeometryArchive, flipH: Bool = false, flipV: Bool = false) -> String {
        let x = Double(g.position.x), y = Double(g.position.y), w = Double(g.size.width), h = Double(g.size.height)
        var t = "translate(\(SVG.n(x)) \(SVG.n(y)))"
        let angle = Double(g.angle)
        if angle != 0 { t += " rotate(\(SVG.n(-angle)) \(SVG.n(w / 2)) \(SVG.n(h / 2)))" }
        if flipH || flipV {
            t += " translate(\(SVG.n(flipH ? w : 0)) \(SVG.n(flipV ? h : 0))) scale(\(flipH ? -1 : 1) \(flipV ? -1 : 1))"
        }
        return t
    }

    mutating func drawShapeInfo(_ info: TSWP_ShapeInfoArchive) {
        let storage = info.hasOwnedStorage ? info.ownedStorage.identifier : info.hasDeprecatedStorage ? info.deprecatedStorage.identifier : nil
        drawShape(info.super, text: storage)
    }

    mutating func drawShape(_ shape: TSD_ShapeArchive, text storage: UInt64?) {
        let d = shape.super
        guard d.hasGeometry else { problems.insert("shape without geometry"); return }
        var look = styles.shapeLook(shape.hasStyle ? shape.style.identifier : nil)
        var g = d.geometry
        if let storage, let sized = selfSizedFrame(g, storage: storage, look: look, path: shape.hasPathsource ? shape.pathsource : nil) {
            guard sized.width > 0, sized.height > 0 else { return }
            g.position = TSP_Point.with { $0.x = Float(sized.x); $0.y = Float(sized.y) }
            g.size = TSP_Size.with { $0.width = Float(sized.width); $0.height = Float(sized.height) }
            look.wraps = sized.wraps
        }
        let w = Double(g.size.width), h = Double(g.size.height)
        let source = shape.hasPathsource ? shape.pathsource : nil
        var group = "<g transform=\"\(transform(g, flipH: source?.horizontalFlip ?? false, flipV: source?.verticalFlip ?? false))\""
        if look.opacity < 0.9995 { group += " opacity=\"\(SVG.n(look.opacity))\"" }
        if let filter = shadowFilter(look.shadow, angle: Double(g.angle)) { group += " filter=\"url(#\(filter))\"" }
        group += ">"
        var inner = ""
        var textSpan: (x0: Double, x1: Double)?
        if let source {
            if let outline = Paths.outline(source) {
                let sx = outline.width > 0 ? w / outline.width : 1, sy = outline.height > 0 ? h / outline.height : 1
                let pathD = outline.d(sx: sx, sy: sy)
                if storage != nil, let span = outline.textSpan, span.x1 - span.x0 < outline.width - 0.5 {
                    textSpan = (span.x0 * sx, span.x1 * sx)
                }
                var art = ""
                if outline.closed, let fill = look.fill {
                    art += paintedPath(fill, d: pathD, w: w, h: h)
                }
                art += stroked(look.stroke, d: pathD)
                if let stroke = look.stroke, visible(stroke), let ends = outline.ends {
                    art += lineEnds(look, stroke: stroke, ends: ends, sx: sx, sy: sy)
                }
                // Geometry flag 4 mirrors the shape left to right, its fill with it (a gradient
                // turns and flips with its shape); its text is not mirrored.
                inner += g.flags & 4 != 0 && !art.isEmpty ? "<g transform=\"translate(\(SVG.n(w)) 0) scale(-1 1)\">" + art + "</g>" : art
            } else {
                problems.insert("path kind")
            }
        }
        if let storage {
            // Text sits in the room inside the outline (a callout's body, not its tail).
            if let span = textSpan {
                inner += "<g transform=\"translate(\(SVG.n(span.x0)) 0)\">" + textMarkup(storage: storage, width: span.x1 - span.x0, height: h, look: look) + "</g>"
            } else {
                inner += textMarkup(storage: storage, width: w, height: h, look: look)
            }
        }
        guard !inner.isEmpty else { return }
        body += group + inner + "</g>"
    }

    /// The frame a text box that sizes itself to its text takes, or nil for a fixed-size box.
    /// Without the geometry's width-valid flag (bit 1) the box grows to its unwrapped text, and its
    /// position is the point it grows from: its left edge, centre or right edge by the first
    /// line's alignment, and its top, centre or bottom by its vertical alignment (Keynote's own
    /// export puts a middle-aligned "Plain text item" at its vertical centre; the size stored
    /// beside the cleared flag is only a cache). A box with a fixed width but no height-valid flag
    /// (bit 2), or a stored height of 0, grows to its text at that width from its left edge.
    /// A line (an open path) that can hold text is never a text box: it stays where it is stored.
    mutating func selfSizedFrame(_ g: TSD_GeometryArchive, storage: UInt64, look: StyleResolver.ShapeLook, path: TSD_PathSourceArchive?) -> (x: Double, y: Double, width: Double, height: Double, wraps: Bool)? {
        let fixedWidth = g.flags & 1 != 0 && g.size.width > 0
        let fixedHeight = g.flags & 2 != 0 && g.size.height > 0
        guard !(fixedWidth && fixedHeight) else { return nil }
        if let path, let outline = Paths.outline(path), !outline.closed { return nil }
        var probe = look
        probe.wraps = fixedWidth
        probe.verticalAlignment = .kFrameAlignTop
        _ = textMarkup(storage: storage, width: fixedWidth ? Double(g.size.width) : 100_000, height: 100_000, look: probe)
        let extent = lastTextExtent
        let width = fixedWidth ? Double(g.size.width) : extent.width
        var x = Double(g.position.x)
        if !fixedWidth {
            switch lastTextAlignment {
            case .tatvalue1: x -= width
            case .tatvalue2: x -= width / 2
            default: break
            }
        }
        // Vertically it keeps the edge its text is aligned to: the top, the centre or the bottom.
        var y = Double(g.position.y)
        switch look.verticalAlignment {
        case .kFrameAlignTop: break
        case .kFrameAlignBottom: y -= extent.height
        default: y -= extent.height / 2
        }
        return (x, y, width, extent.height, fixedWidth)
    }

    mutating func drawGroup(_ group: TSD_GroupArchive) {
        // A group flips (flag 4) as a picture does; its children are placed from its position at
        // their own size (a freehand drawing stores a size well under a point).
        let g = group.super.geometry
        var open = "<g transform=\"\(transform(g, flipH: g.flags & 4 != 0))\""
        // A freehand drawing (Keynote's pencil) keeps its own opacity on the group.
        let drawing = group.TSD_FreehandDrawingArchive_freehandDrawingArchive
        if drawing.hasOpacity, drawing.opacity < 0.9995 { open += " opacity=\"\(SVG.n(max(0, drawing.opacity)))\"" }
        body += open + ">"
        for child in group.children { drawDrawable(child.identifier) }
        body += "</g>"
    }

    // MARK: Images

    func dataFile(_ id: UInt64) -> (name: String, bytes: Data)? {
        guard let info = document.packageMetadata?.datas.first(where: { $0.identifier == id }),
              let bytes = document.package.data("Data/" + info.fileName) else { return nil }
        // A browser cannot draw an Apple icon file: its largest PNG rendition stands in, or, with
        // none, nothing (a picture then falls back to Keynote's small copy).
        if info.fileName.lowercased().hasSuffix(".icns") {
            guard let png = Self.largestPNG(inIcon: bytes) else { return nil }
            return ((info.fileName as NSString).deletingPathExtension + ".png", png)
        }
        return (info.fileName, bytes)
    }

    mutating func drawImage(_ image: TSD_ImageArchive) {
        let d = image.super
        guard d.hasGeometry else { problems.insert("image without geometry"); return }
        // A deck made from a built-in theme carries only the small copy of a theme photo; Keynote
        // takes the full one from its own bundle. The small copy stands in for it.
        // A picture with Keynote's adjustments (exposure, saturation, a theme's recolouring) shows
        // the adjusted copy Keynote saved beside the original.
        let candidates = [image.hasAdjustedImageData ? image.adjustedImageData.identifier : nil,
                          image.hasData ? image.data.identifier : nil, image.hasThumbnailData ? image.thumbnailData.identifier : nil]
        var found: (name: String, bytes: Data)?
        for id in candidates.compactMap({ $0 }) where found == nil { found = dataFile(id) }
        guard let file = found else { problems.insert("image data"); return }
        if image.hasData, dataFile(image.data.identifier) == nil, !(image.hasAdjustedImageData && dataFile(image.adjustedImageData.identifier) != nil) {
            problems.insert("theme photo (small copy)")
        }
        let g = d.geometry
        let w = Double(g.size.width), h = Double(g.size.height)
        let look = styles.mediaLook(image.hasStyle ? image.style.identifier : nil)
        // The stroke follows what shows: the mask's outline, or the image's frame.
        var edge = (transform: "", d: Outline(commands: Paths.rect(w, h, radius: 0), width: w, height: h).d())
        var placement = "width=\"\(SVG.n(w))\" height=\"\(SVG.n(h))\""
        var cropToFrame = false
        // Keynote draws a PDF's art (the box its natural size names), not its whole page, which
        // is what a browser draws: the page is sized and moved so that box fills the frame.
        if file.name.lowercased().hasSuffix(".pdf"), image.hasNaturalSize,
           let boxes = Self.pdfBoxes(file.bytes, natural: (Double(image.naturalSize.width), Double(image.naturalSize.height))) {
            let (page, art) = boxes
            let sx = w / art.w, sy = h / art.h
            placement = "x=\"\(SVG.n(-(art.x - page.x) * sx))\" y=\"\(SVG.n(-((page.y + page.h) - (art.y + art.h)) * sy))\" width=\"\(SVG.n(page.w * sx))\" height=\"\(SVG.n(page.h * sy))\""
            cropToFrame = true
        }
        var element = "<image href=\"\(SVG.escape(imageHref(file.name, file.bytes)))\" \(placement) preserveAspectRatio=\"none\""
        // A mask crops the image: its frame sits in the image's frame coordinates.
        if image.hasMask, let mask = document.decoded(TSD_MaskArchive.self, image.mask.identifier), mask.super.hasGeometry {
            let mg = mask.super.geometry
            let mw = Double(mg.size.width), mh = Double(mg.size.height)
            let outline = mask.hasPathsource ? Paths.outline(mask.pathsource) : nil
            let pathD: String
            if let outline, outline.width > 0, outline.height > 0 {
                pathD = outline.d(sx: mw / outline.width, sy: mh / outline.height)
            } else {
                pathD = Outline(commands: Paths.rect(mw, mh, radius: 0), width: mw, height: mh).d()
            }
            let maskTransform = transform(mg)
            edge = (maskTransform, pathD)
            let clip = defs.add { "<clipPath id=\"\($0)\"><path transform=\"\(maskTransform)\" d=\"\(pathD)\"/></clipPath>" }
            element += " clip-path=\"url(#\(clip))\""
            cropToFrame = false
        }
        if cropToFrame {
            let clip = defs.add { "<clipPath id=\"\($0)\"><rect width=\"\(SVG.n(w))\" height=\"\(SVG.n(h))\"/></clipPath>" }
            element += " clip-path=\"url(#\(clip))\""
        }
        element += "/>"
        // Instant Alpha keeps what its path encloses, in the picture's natural size; the file
        // holds the untouched picture.
        if image.hasInstantAlphaPath, image.hasNaturalSize, image.naturalSize.width > 0, image.naturalSize.height > 0 {
            let commands = Paths.commands(image.instantAlphaPath)
            if !commands.isEmpty, commands.count <= 200_000 {
                let sx = w / Double(image.naturalSize.width), sy = h / Double(image.naturalSize.height)
                let pathD = Outline(commands: commands, width: w, height: h).d(sx: sx, sy: sy)
                let clip = defs.add { "<clipPath id=\"\($0)\"><path clip-rule=\"evenodd\" d=\"\(pathD)\"/></clipPath>" }
                element = "<g clip-path=\"url(#\(clip))\">" + element + "</g>"
            }
        }
        // Geometry flag bit 4 mirrors a picture left to right (Flip Horizontally).
        var group = "<g transform=\"\(transform(g, flipH: g.flags & 4 != 0))\""
        if look.opacity < 0.9995 { group += " opacity=\"\(SVG.n(look.opacity))\"" }
        if let filter = shadowFilter(look.shadow, angle: Double(g.angle)) { group += " filter=\"url(#\(filter))\"" }
        body += group + ">" + element
        if let stroke = look.stroke {
            let open = edge.transform.isEmpty ? "" : "<g transform=\"\(edge.transform)\">"
            if stroke.hasFrame {
                // A picture frame is artwork in Keynote's bundle, not in the file: a light mat
                // of the frame's usual width stands in for it.
                problems.insert("picture frame (approximated)")
                let width = 24 * (stroke.frame.hasAssetScale ? Double(stroke.frame.assetScale) : 1)
                body += open + "<path d=\"\(edge.d)\" fill=\"none\" stroke=\"#f7f5ef\" stroke-width=\"\(SVG.n(width))\"/>" + (open.isEmpty ? "" : "</g>")
            } else if visible(stroke) {
                body += open + stroked(stroke, d: edge.d) + (open.isEmpty ? "" : "</g>")
            }
        }
        body += "</g>"
    }

    mutating func drawMovie(_ movie: TSD_MovieArchive) {
        let d = movie.super
        guard d.hasGeometry, movie.hasPosterImageData, let file = dataFile(movie.posterImageData.identifier) else {
            // Audio has no picture on the slide in a PDF export.
            return
        }
        let g = d.geometry
        body += "<image transform=\"\(transform(g))\" href=\"\(SVG.escape(imageHref(file.name, file.bytes)))\" width=\"\(SVG.n(Double(g.size.width)))\" height=\"\(SVG.n(Double(g.size.height)))\" preserveAspectRatio=\"none\"/>"
    }

    // MARK: Paint

    /// A drop shadow as an SVG filter: `offset` points along Keynote's angle (315° is down and to
    /// the right), blurred by its radius. The drawable's own rotation turns the filter's space,
    /// so the offset is turned back to stay fixed on the slide.
    mutating func shadowFilter(_ shadow: TSD_ShadowArchive?, angle rotation: Double) -> String? {
        // An empty `shadow {}` in a style (every field at its default: on, black, opacity 1)
        // draws nothing in Keynote; a real shadow always stores its colour.
        guard let shadow, shadow.hasColor, shadow.isEnabled, shadow.opacity > 0 else { return nil }
        let a = (Double(shadow.angle) - rotation) * .pi / 180
        let offset = Double(shadow.offset)
        let dx = offset * cos(a), dy = -offset * sin(a)
        let color = shadow.hasColor ? SVG.RGBA(shadow.color) : SVG.RGBA(r: 0, g: 0, b: 0, a: 1)
        let opacity = max(0, min(1, Double(shadow.opacity) * color.a))
        let blur = max(0, Double(shadow.radius)) / 2
        if shadow.type != .tsddropShadow { problems.insert("shadow style (drawn as a drop shadow)") }
        return defs.add { "<filter id=\"\($0)\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\"><feDropShadow dx=\"\(SVG.n(dx))\" dy=\"\(SVG.n(dy))\" stdDeviation=\"\(SVG.n(blur))\" flood-color=\"\(color.hex)\" flood-opacity=\"\(SVG.n(opacity))\"/></filter>" }
    }

    func visible(_ stroke: TSD_StrokeArchive) -> Bool {
        if stroke.hasPattern, stroke.pattern.type == .tsdemptyPattern { return false }
        return stroke.hasColor && stroke.width > 0
    }

    func stroked(_ stroke: TSD_StrokeArchive?, d: String) -> String {
        guard let stroke, visible(stroke) else { return "" }
        var s = "<path d=\"\(d)\" fill=\"none\"" + SVG.paint("stroke", SVG.RGBA(stroke.color)) + " stroke-width=\"\(SVG.n(stroke.width))\""
        switch stroke.cap {
        case .roundCap: s += " stroke-linecap=\"round\""
        case .squareCap: s += " stroke-linecap=\"square\""
        default: break
        }
        switch stroke.join {
        case .roundJoin: s += " stroke-linejoin=\"round\""
        case .bevelJoin: s += " stroke-linejoin=\"bevel\""
        default: if stroke.hasMiterLimit { s += " stroke-miterlimit=\"\(SVG.n(max(1, stroke.miterLimit)))\"" }
        }
        if stroke.hasPattern, stroke.pattern.type == .tsdpattern {
            let count = min(Int(stroke.pattern.count), stroke.pattern.pattern.count)
            if count > 0 {
                let dashes = stroke.pattern.pattern.prefix(count).map { SVG.n(Double($0) * Double(stroke.width)) }
                s += " stroke-dasharray=\"\(dashes.joined(separator: " "))\""
            }
        }
        return s + "/>"
    }

    /// Arrowheads and other line ends, drawn filled in the stroke's colour.
    mutating func lineEnds(_ look: StyleResolver.ShapeLook, stroke: TSD_StrokeArchive,
                           ends: (start: (Double, Double), startToward: (Double, Double), end: (Double, Double), endFrom: (Double, Double)),
                           sx: Double, sy: Double) -> String {
        var out = ""
        let width = max(1, Double(stroke.width))
        func place(_ end: TSD_LineEndArchive?, at p: (Double, Double), from q: (Double, Double)) {
            guard let end, end.hasPath, !end.path.elements.isEmpty else { return }
            let tip = (p.0 * sx, p.1 * sy), back = (q.0 * sx, q.1 * sy)
            let angle = atan2(tip.1 - back.1, tip.0 - back.0) * 180 / .pi
            // A line end's path is drawn pointing along +x with its end point at the line's end,
            // scaled by the stroke width.
            let e = end.hasEndPoint ? (Double(end.endPoint.x), Double(end.endPoint.y)) : (0, 0)
            let d = Outline(commands: Paths.commands(end.path), width: 1, height: 1).d()
            let t = "translate(\(SVG.n(tip.0)) \(SVG.n(tip.1))) rotate(\(SVG.n(angle))) scale(\(SVG.n(width))) translate(\(SVG.n(-e.0)) \(SVG.n(-e.1)))"
            let color = SVG.RGBA(stroke.color)
            if end.isFilled {
                out += "<path transform=\"\(t)\" d=\"\(d)\"" + SVG.paint("fill", color) + "/>"
            } else {
                out += "<path transform=\"\(t)\" d=\"\(d)\" fill=\"none\"" + SVG.paint("stroke", color) + " stroke-width=\"1\"/>"
            }
        }
        place(look.headLineEnd, at: ends.start, from: ends.startToward)
        place(look.tailLineEnd, at: ends.end, from: ends.endFrom)
        return out
    }

    /// A gradient as a `<linearGradient>`/`<radialGradient>` over the box, or nil for none.
    mutating func gradient(_ g: TSD_GradientArchive, w: Double, h: Double, origin: (x: Double, y: Double) = (0, 0)) -> String? {
        let stops = g.stops.map { stop -> String in
            let c = SVG.RGBA(stop.color)
            var s = "<stop offset=\"\(SVG.n(stop.fraction))\" stop-color=\"\(c.hex)\""
            let a = c.a * (g.hasOpacity ? Double(g.opacity) : 1)
            if a < 0.9995 { s += " stop-opacity=\"\(SVG.n(a))\"" }
            return s + "/>"
        }.joined()
        guard !g.stops.isEmpty else { return nil }
        if g.type == .radial {
            let r = sqrt(w * w + h * h) / 2
            return defs.add { "<radialGradient id=\"\($0)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(SVG.n(origin.x + w / 2))\" cy=\"\(SVG.n(origin.y + h / 2))\" r=\"\(SVG.n(r))\">\(stops)</radialGradient>" }
        }
        var start = (0.0, h / 2), end = (w, h / 2)
        if g.hasTransformgradient {
            let t = g.transformgradient
            let bw = t.hasBaseNaturalSize && t.baseNaturalSize.width > 0 ? Double(t.baseNaturalSize.width) : w
            let bh = t.hasBaseNaturalSize && t.baseNaturalSize.height > 0 ? Double(t.baseNaturalSize.height) : h
            start = (Double(t.start.x) * w / bw, Double(t.start.y) * h / bh)
            end = (Double(t.end.x) * w / bw, Double(t.end.y) * h / bh)
        } else {
            // The angle is in radians, counterclockwise from +x in the shape's own frame (5.50,
            // 315°, runs top left to bottom right), turning and flipping with the shape.
            let a = Double(g.hasAnglegradient ? g.anglegradient.gradientangle : 0)
            let dx = cos(a), dy = -sin(a)
            let half = abs(w * dx) / 2 + abs(h * dy) / 2
            start = (w / 2 - dx * half, h / 2 - dy * half)
            end = (w / 2 + dx * half, h / 2 + dy * half)
        }
        start = (start.0 + origin.x, start.1 + origin.y); end = (end.0 + origin.x, end.1 + origin.y)
        return defs.add { "<linearGradient id=\"\($0)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(SVG.n(start.0))\" y1=\"\(SVG.n(start.1))\" x2=\"\(SVG.n(end.0))\" y2=\"\(SVG.n(end.1))\">\(stops)</linearGradient>" }
    }

    mutating func paintedRect(_ fill: TSD_FillArchive, x: Double, y: Double, w: Double, h: Double) -> String {
        let d = "M\(SVG.n(x)) \(SVG.n(y))H\(SVG.n(x + w))V\(SVG.n(y + h))H\(SVG.n(x))Z"
        return paintedPath(fill, d: d, w: w, h: h)
    }

    /// A closed outline filled with `fill`: a colour, a gradient, or an image clipped to it.
    mutating func paintedPath(_ fill: TSD_FillArchive, d: String, w: Double, h: Double) -> String {
        if fill.hasColor {
            return "<path d=\"\(d)\"" + SVG.paint("fill", SVG.RGBA(fill.color)) + "/>"
        }
        if fill.hasGradient, let id = gradient(fill.gradient, w: w, h: h) {
            return "<path d=\"\(d)\" fill=\"url(#\(id))\"/>"
        }
        if fill.hasImage {
            let image = fill.image
            let dataID = image.hasImagedata ? image.imagedata.identifier : image.hasOriginalimagedata ? image.originalimagedata.identifier : nil
            guard let dataID, let file = dataFile(dataID) else {
                // A built-in theme's texture or photo is not in the file: Keynote downloads it.
                // The fill's reference colour (its image's average) stands in for it.
                if image.hasReferencecolor {
                    problems.insert("theme image (reference colour)")
                    return "<path d=\"\(d)\"" + SVG.paint("fill", SVG.RGBA(image.referencecolor)) + "/>"
                }
                problems.insert("image fill data")
                return ""
            }
            let clip = defs.add { "<clipPath id=\"\($0)\"><path d=\"\(d)\"/></clipPath>" }
            let href = SVG.escape(imageHref(file.name, file.bytes))
            var out = "<g clip-path=\"url(#\(clip))\">"
            if image.hasTint {
                out += "<path d=\"\(d)\"" + SVG.paint("fill", SVG.RGBA(image.tint)) + "/>"
            }
            switch image.technique {
            case .stretch:
                out += "<image href=\"\(href)\" width=\"\(SVG.n(w))\" height=\"\(SVG.n(h))\" preserveAspectRatio=\"none\"/>"
            case .scaleToFit:
                out += "<image href=\"\(href)\" width=\"\(SVG.n(w))\" height=\"\(SVG.n(h))\" preserveAspectRatio=\"xMidYMid meet\"/>"
            case .tile, .naturalSize:
                let fw = image.hasFillsize ? Double(image.fillsize.width) : w, fh = image.hasFillsize ? Double(image.fillsize.height) : h
                if image.technique == .tile, fw > 0, fh > 0 {
                    let pattern = defs.add { "<pattern id=\"\($0)\" patternUnits=\"userSpaceOnUse\" width=\"\(SVG.n(fw))\" height=\"\(SVG.n(fh))\"><image href=\"\(href)\" width=\"\(SVG.n(fw))\" height=\"\(SVG.n(fh))\" preserveAspectRatio=\"none\"/></pattern>" }
                    out += "<path d=\"\(d)\" fill=\"url(#\(pattern))\"/>"
                } else {
                    out += "<image href=\"\(href)\" x=\"\(SVG.n((w - fw) / 2))\" y=\"\(SVG.n((h - fh) / 2))\" width=\"\(SVG.n(fw))\" height=\"\(SVG.n(fh))\" preserveAspectRatio=\"none\"/>"
                }
            default:
                out += "<image href=\"\(href)\" width=\"\(SVG.n(w))\" height=\"\(SVG.n(h))\" preserveAspectRatio=\"xMidYMid slice\"/>"
            }
            return out + "</g>"
        }
        return ""
    }

    /// The largest PNG among an `.icns` file's renditions (`ic07`…`ic14` hold PNG or JPEG 2000).
    static func largestPNG(inIcon bytes: Data) -> Data? {
        let b = [UInt8](bytes.prefix(64 << 20))
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        guard b.count >= 8, b[0...3] == [0x69, 0x63, 0x6E, 0x73] else { return nil }  // 'icns'
        let end = min(b.count, u32(4))
        var offset = 8, best: Range<Int>?
        for _ in 0..<512 where offset + 8 <= end {
            let length = u32(offset + 4)
            guard length >= 8, offset + length <= end else { break }
            let data = (offset + 8)..<(offset + length)
            if data.count > 8, b[data.lowerBound..<data.lowerBound + 8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
               data.count > (best?.count ?? 0) {
                best = data
            }
            offset += length
        }
        return best.map { Data(b[$0]) }
    }

    typealias Box = (x: Double, y: Double, w: Double, h: Double)

    /// A PDF's first page box and the box Keynote shows (Art, Trim or Crop, whichever matches
    /// the picture's natural size within a point), read from the file's text; nil when they are
    /// not found as plain text (an object stream), match nothing, or are the page itself.
    static func pdfBoxes(_ bytes: Data, natural: (Double, Double)) -> (page: Box, art: Box)? {
        func box(_ key: String) -> Box? {
            guard let range = bytes.range(of: Data(("/" + key).utf8)) else { return nil }
            let tail = bytes[range.upperBound..<min(bytes.endIndex, range.upperBound + 200)]
            guard let open = tail.firstIndex(of: UInt8(ascii: "[")), let close = tail[open...].firstIndex(of: UInt8(ascii: "]")) else { return nil }
            let numbers = String(decoding: tail[(open + 1)..<close], as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).compactMap { Double($0) }
            guard numbers.count == 4, numbers.allSatisfy(\.isFinite) else { return nil }
            let x0 = min(numbers[0], numbers[2]), y0 = min(numbers[1], numbers[3])
            let b = (x: x0, y: y0, w: abs(numbers[2] - numbers[0]), h: abs(numbers[3] - numbers[1]))
            return b.w > 0 && b.h > 0 ? b : nil
        }
        guard let page = box("MediaBox"), natural.0 > 0, natural.1 > 0 else { return nil }
        for key in ["ArtBox", "TrimBox", "CropBox"] {
            if let art = box(key), abs(art.w - natural.0) < 1, abs(art.h - natural.1) < 1 {
                if abs(art.w - page.w) < 1 && abs(art.h - page.h) < 1 { return nil }
                return (page, art)
            }
        }
        return nil
    }

    static let placeholderType: UInt32 = 7
    static let shapeInfoType: UInt32 = 2011
    static let equationType: UInt32 = 2015
    static let shapeType: UInt32 = 3004
    static let imageType: UInt32 = 3005
    static let movieType: UInt32 = 3007
    static let groupType: UInt32 = 3008
    static let connectionLineType: UInt32 = 3009
    static let chartType: UInt32 = 5021
    static let tableType: UInt32 = 6000
    static let wpTableType: UInt32 = 6007
}
