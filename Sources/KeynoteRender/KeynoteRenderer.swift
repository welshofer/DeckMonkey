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
    public let document: KeynoteDocument
    public let fonts: RenderFonts?
    /// How an image file becomes an `href`: by default a `data:` URI of the file's bytes.
    public var imageHref: (_ fileName: String, _ bytes: Data) -> String = KeynoteRenderer.dataURI

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
        // A text box that sizes itself to its text stores 0 × 0 at its left edge and vertical
        // centre (Keynote's own export puts "Plain text item" there): lay the text out unwrapped
        // to find its size.
        // A box with a width but height 0 grows to its text at that width, stored the same way.
        if let storage, g.size.height == 0 {
            let fixedWidth = g.size.width > 0
            var probe = look
            probe.wraps = fixedWidth
            probe.verticalAlignment = .kFrameAlignTop
            _ = textMarkup(storage: storage, width: fixedWidth ? Double(g.size.width) : 100_000, height: 100_000, look: probe)
            let extent = lastTextExtent
            guard extent.width > 0, extent.height > 0 else { return }
            g.position.y -= Float(extent.height / 2)
            g.size = TSP_Size.with { $0.width = fixedWidth ? g.size.width : Float(extent.width); $0.height = Float(extent.height) }
            look.wraps = fixedWidth
        }
        let w = Double(g.size.width), h = Double(g.size.height)
        let source = shape.hasPathsource ? shape.pathsource : nil
        var group = "<g transform=\"\(transform(g, flipH: source?.horizontalFlip ?? false, flipV: source?.verticalFlip ?? false))\""
        if look.opacity < 0.9995 { group += " opacity=\"\(SVG.n(look.opacity))\"" }
        if let filter = shadowFilter(look.shadow, angle: Double(g.angle)) { group += " filter=\"url(#\(filter))\"" }
        group += ">"
        var inner = ""
        if let source {
            if let outline = Paths.outline(source) {
                let sx = outline.width > 0 ? w / outline.width : 1, sy = outline.height > 0 ? h / outline.height : 1
                let pathD = outline.d(sx: sx, sy: sy)
                if outline.closed, let fill = look.fill {
                    inner += paintedPath(fill, d: pathD, w: w, h: h)
                }
                inner += stroked(look.stroke, d: pathD)
                if let stroke = look.stroke, visible(stroke), let ends = outline.ends {
                    inner += lineEnds(look, stroke: stroke, ends: ends, sx: sx, sy: sy)
                }
            } else {
                problems.insert("path kind")
            }
        }
        if let storage {
            inner += textMarkup(storage: storage, width: w, height: h, look: look)
        }
        guard !inner.isEmpty else { return }
        body += group + inner + "</g>"
    }

    mutating func drawGroup(_ group: TSD_GroupArchive) {
        let g = group.super.geometry
        body += "<g transform=\"\(transform(g))\">"
        for child in group.children { drawDrawable(child.identifier) }
        body += "</g>"
    }

    // MARK: Images

    func dataFile(_ id: UInt64) -> (name: String, bytes: Data)? {
        guard let info = document.packageMetadata?.datas.first(where: { $0.identifier == id }),
              let bytes = document.package.data("Data/" + info.fileName) else { return nil }
        return (info.fileName, bytes)
    }

    mutating func drawImage(_ image: TSD_ImageArchive) {
        let d = image.super
        guard d.hasGeometry else { problems.insert("image without geometry"); return }
        // A deck made from a built-in theme carries only the small copy of a theme photo; Keynote
        // takes the full one from its own bundle. The small copy stands in for it.
        let candidates = [image.hasData ? image.data.identifier : nil, image.hasThumbnailData ? image.thumbnailData.identifier : nil]
        var found: (name: String, bytes: Data)?
        for id in candidates.compactMap({ $0 }) where found == nil { found = dataFile(id) }
        guard let file = found else { problems.insert("image data"); return }
        if image.hasData, dataFile(image.data.identifier) == nil { problems.insert("theme photo (small copy)") }
        let g = d.geometry
        let w = Double(g.size.width), h = Double(g.size.height)
        let look = styles.mediaLook(image.hasStyle ? image.style.identifier : nil)
        // The stroke follows what shows: the mask's outline, or the image's frame.
        var edge = (transform: "", d: Outline(commands: Paths.rect(w, h, radius: 0), width: w, height: h).d())
        var element = "<image href=\"\(SVG.escape(imageHref(file.name, file.bytes)))\" width=\"\(SVG.n(w))\" height=\"\(SVG.n(h))\" preserveAspectRatio=\"none\""
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
        }
        element += "/>"
        var group = "<g transform=\"\(transform(g))\""
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
        guard let shadow, shadow.isEnabled, shadow.opacity > 0 else { return nil }
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
    mutating func gradient(_ g: TSD_GradientArchive, w: Double, h: Double) -> String? {
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
            return defs.add { "<radialGradient id=\"\($0)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(SVG.n(w / 2))\" cy=\"\(SVG.n(h / 2))\" r=\"\(SVG.n(r))\">\(stops)</radialGradient>" }
        }
        var start = (0.0, h / 2), end = (w, h / 2)
        if g.hasTransformgradient {
            let t = g.transformgradient
            let bw = t.hasBaseNaturalSize && t.baseNaturalSize.width > 0 ? Double(t.baseNaturalSize.width) : w
            let bh = t.hasBaseNaturalSize && t.baseNaturalSize.height > 0 ? Double(t.baseNaturalSize.height) : h
            start = (Double(t.start.x) * w / bw, Double(t.start.y) * h / bh)
            end = (Double(t.end.x) * w / bw, Double(t.end.y) * h / bh)
        } else {
            let a = Double(g.hasAnglegradient ? g.anglegradient.gradientangle : 0) * .pi / 180
            let dx = cos(a), dy = -sin(a)
            let half = abs(w * dx) / 2 + abs(h * dy) / 2
            start = (w / 2 - dx * half, h / 2 - dy * half)
            end = (w / 2 + dx * half, h / 2 + dy * half)
        }
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
}
