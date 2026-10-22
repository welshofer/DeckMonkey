import Foundation
import IWASchema
import KeynoteGraph

/// What `build(_:)` made.
public struct SceneBuildReport: Equatable, Sendable {
    public var slides: [UInt64]
    public var drawables: Int
    public var styles: Int
}

extension KeynoteDocument {
    public enum SceneBuildFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case noMaster(String)
        case badColor(String)
        case notAShape(UInt64)

        public var description: String {
            switch self {
            case .noMaster(let name): return "the template has no master named \(name)"
            case .badColor(let c): return "\(c) is not a colour (#rrggbb[aa], color(srgb r g b[ / a]) or color(display-p3 r g b[ / a]))"
            case .notAShape(let id): return "inserted object \(id) is not a shape"
            }
        }
    }

    /// Replaces this deck's slides with `scene`'s: the slide size is set, each scene slide becomes a
    /// slide on `master`, and each drawable a copy of a Keynote-made part (a text item, a shape, a
    /// line) with the scene's outline and geometry and its look as style variations over the
    /// theme's styles. Identical looks share one variation.
    @discardableResult
    public mutating func build(_ scene: Scene, master masterName: String = "Blank") throws -> SceneBuildReport {
        guard let master = masters().first(where: { $0.name == masterName }) ?? masters().first else { throw SceneBuildFailure.noMaster(masterName) }
        if let showID = showIdentifier, var show = decoded(KN_ShowArchive.self, showID) {
            show.size = TSP_Size.with { $0.width = Float(scene.width); $0.height = Float(scene.height) }
            try replacePayload(of: showID, with: try show.serializedData(partial: true))
        }
        let existing = try slideList().count
        var slides = [UInt64]()
        for _ in scene.slides { slides.append(try addSlide(fromMaster: master.id).slide) }
        for _ in 0..<existing { try deleteSlide(at: 0) }

        let parts = (text: try Parts.document(.textBox), shape: try Parts.document(.shape), line: try Parts.document(.line))
        func firstDrawable(_ d: KeynoteDocument) -> UInt64 {
            d.store.identifiers.first { d.store.record(for: $0)?.info.messageInfos.first?.type == 2011 }!
        }
        let sources = (text: firstDrawable(parts.text), shape: firstDrawable(parts.shape), line: firstDrawable(parts.line))
        var shapeStyles = [String: UInt64](), paragraphStyles = [String: UInt64]()
        var count = 0
        var batch = try beginInserts()
        for (slide, sceneSlide) in zip(slides, scene.slides) {
            for d in sceneSlide.drawables {
                let (source, id) = d.textBox ? (parts.text, sources.text) : d.isOpen ? (parts.line, sources.line) : (parts.shape, sources.shape)
                let paragraphs = d.text.map { $0.paragraphs.map { TextParagraphs.Paragraph($0.text) } }
                let new = try insertDrawable(id, from: source, onto: slide, frame: Frame(x: d.x, y: d.y, width: max(d.width, 1), height: max(d.height, 1)),
                                             paragraphs: paragraphs, batch: &batch)
                guard var shape = decoded(TSWP_ShapeInfoArchive.self, new) else { throw SceneBuildFailure.notAShape(new) }

                // Geometry and outline exactly as the scene gives them.
                var g = shape.super.super.geometry
                g.position = .with { $0.x = Float(d.x); $0.y = Float(d.y) }
                // A dimension the text sizes is stored as 0, its laid-out size kept as the path's.
                g.size = .with { $0.width = d.autoWidth ? 0 : Float(d.width); $0.height = d.autoHeight ? 0 : Float(d.height) }
                g.angle = Float(d.angle)
                g.flags = (d.autoWidth ? 0 : 1) | (d.autoHeight ? 0 : 2) | (d.flipped ? 4 : 0)
                shape.super.super.geometry = g
                if !d.path.isEmpty {
                    var bezier = TSD_BezierPathSourceArchive()
                    bezier.naturalSize = .with { $0.width = Float(d.width); $0.height = Float(d.height) }
                    bezier.path = Self.scenePath(d.path)
                    shape.super.pathsource.bezierPathSource = bezier
                }

                // Its look: one shape style variation per distinct fill, stroke and text frame.
                let parent = shape.super.style.identifier
                let fill: TSD_FillArchive?? = .some(try d.fill.map(Self.sceneFill))
                // No stroke in the scene is none on the page, whatever the theme's default.
                let stroke = try d.stroke.map(Self.sceneStroke) ?? Self.noStroke
                var valign: TSWP_ShapeStylePropertiesArchive.VerticalAlignmentType?
                var padding: TSWP_PaddingArchive?
                if let t = d.text {
                    valign = t.verticalAlignment == .middle ? .kFrameAlignMiddle : t.verticalAlignment == .bottom ? .kFrameAlignBottom : .kFrameAlignTop
                    padding = .with { $0.left = Float(t.padding[0]); $0.top = Float(t.padding[1]); $0.right = Float(t.padding[2]); $0.bottom = Float(t.padding[3]) }
                }
                let key = "\(parent)|\(try fill.flatMap { $0 }?.serializedData(partial: true).base64EncodedString() ?? "none")|\(try stroke.serializedData(partial: true).base64EncodedString())|\(valign.map { "\($0.rawValue)" } ?? "-")|\(padding.map { "\($0.left),\($0.top),\($0.right),\($0.bottom)" } ?? "-")"
                let style: UInt64
                if let known = shapeStyles[key] { style = known } else {
                    style = try shapeStyleVariation(over: parent, fill: fill, stroke: stroke, verticalAlignment: valign, padding: padding)
                    shapeStyles[key] = style
                }
                shape.super.style = .with { $0.identifier = style }
                try replacePayload(of: new, with: try shape.serializedData(partial: true))

                // Its text: each paragraph in a paragraph style variation for its font, size,
                // colour and alignment.
                if let t = d.text, shape.hasOwnedStorage, var storage = decoded(TSWP_StorageArchive.self, shape.ownedStorage.identifier) {
                    var offset = 0
                    var entries = [TSWP_ObjectAttributeTable.ObjectAttribute]()
                    for p in t.paragraphs {
                        let base = storage.tableParaStyle.entries.first(where: \.hasObject)?.object.identifier ?? 0
                        let pkey = "\(base)|\(p.font)|\(p.size)|\(p.color)|\(p.alignment.rawValue)"
                        let pstyle: UInt64
                        if let known = paragraphStyles[pkey] { pstyle = known } else {
                            var c = TSWP_CharacterStylePropertiesArchive()
                            c.fontName = p.font
                            c.fontSize = Float(p.size)
                            let color = try Self.sceneColor(p.color)
                            c.fontColor = color
                            c.tsdFill = .with { $0.color = color }
                            var para = TSWP_ParagraphStylePropertiesArchive()
                            switch p.alignment {
                            case .left: para.alignment = .tatvalue0
                            case .right: para.alignment = .tatvalue1
                            case .center: para.alignment = .tatvalue2
                            case .justified: para.alignment = .tatvalue3
                            case .natural: para.alignment = .tatvalue4
                            }
                            pstyle = try paragraphStyleVariation(over: base, character: c, paragraph: para)
                            paragraphStyles[pkey] = pstyle
                        }
                        entries.append(TSWP_ObjectAttributeTable.ObjectAttribute.with { $0.characterIndex = UInt32(offset); $0.object = .with { $0.identifier = pstyle } })
                        offset += p.text.utf16.count + 1
                    }
                    storage.tableParaStyle.entries = entries
                    try replacePayload(of: shape.ownedStorage.identifier, with: try storage.serializedData(partial: true))
                }
                count += 1
            }
        }
        try finishInserts(batch)
        return SceneBuildReport(slides: slides, drawables: count, styles: shapeStyles.count + paragraphStyles.count)
    }

    static func scenePath(_ elements: [ScenePathElement]) -> TSP_Path {
        var path = TSP_Path()
        for e in elements {
            var element = TSP_Path.Element()
            switch e.op {
            case .move: element.type = .moveTo
            case .line: element.type = .lineTo
            case .curve: element.type = .curveTo
            case .close: element.type = .closeSubpath
            }
            for i in stride(from: 0, to: e.points.count - 1, by: 2) {
                element.points.append(.with { $0.x = Float(e.points[i]); $0.y = Float(e.points[i + 1]) })
            }
            path.elements.append(element)
        }
        return path
    }

    static func sceneColor(_ text: String) throws -> TSP_Color {
        let spec = text.trimmingCharacters(in: .whitespaces)
        if spec.hasPrefix("color("), spec.hasSuffix(")") {
            let words = spec.dropFirst("color(".count).dropLast().split(whereSeparator: { $0 == " " || $0 == "/" }).map(String.init)
            let values = words.dropFirst().compactMap(Float.init)
            guard words.count == 4 || words.count == 5, ["srgb", "display-p3"].contains(words[0]), values.count == words.count - 1,
                  values.allSatisfy({ (0...1).contains($0) }) else { throw SceneBuildFailure.badColor(text) }
            return .with {
                $0.model = .rgb
                $0.r = values[0]; $0.g = values[1]; $0.b = values[2]; $0.a = values.count == 4 ? values[3] : 1
                $0.rgbspace = words[0] == "display-p3" ? .p3 : .srgb
            }
        }
        let digits = spec.hasPrefix("#") ? String(spec.dropFirst()) : spec
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { throw SceneBuildFailure.badColor(text) }
        let v = digits.count == 6 ? value << 8 | 0xFF : value
        return .with {
            $0.model = .rgb
            $0.r = Float((v >> 24) & 0xFF) / 255; $0.g = Float((v >> 16) & 0xFF) / 255; $0.b = Float((v >> 8) & 0xFF) / 255
            $0.a = Float(v & 0xFF) / 255
            $0.rgbspace = .srgb
        }
    }

    static func sceneFill(_ fill: SceneFill) throws -> TSD_FillArchive {
        if let g = fill.gradient {
            var gradient = TSD_GradientArchive()
            gradient.type = g.radial ? .radial : .linear
            gradient.stops = try g.stops.map { s in try .with { $0.color = try sceneColor(s.color); $0.fraction = Float(s.fraction); $0.inflection = 0.5 } }
            gradient.opacity = 1
            gradient.anglegradient = .with { $0.gradientangle = Float(g.angle) }
            return .with { $0.gradient = gradient }
        }
        if let c = fill.color { return try .with { $0.color = try sceneColor(c) } }
        return TSD_FillArchive()
    }

    /// Keynote's "No Border": a stroke with the empty pattern.
    static let noStroke = TSD_StrokeArchive.with {
        $0.color = .with { $0.model = .rgb; $0.r = 0; $0.g = 0; $0.b = 0; $0.a = 1 }
        $0.width = 1
        $0.cap = .buttCap
        $0.join = .miterJoin
        $0.miterLimit = 4
        $0.pattern = .with { $0.type = .tsdemptyPattern }
    }

    static func sceneStroke(_ stroke: SceneStroke) throws -> TSD_StrokeArchive {
        try .with {
            $0.color = try sceneColor(stroke.color)
            $0.width = Float(stroke.width)
            $0.cap = .buttCap
            $0.join = .miterJoin
            $0.miterLimit = 4
            $0.pattern = .with { $0.type = .tsdsolidPattern }
        }
    }
}
