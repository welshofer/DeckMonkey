import Foundation

/// A deck as plain data: its slide size and, per slide, the drawables to put on it, each an
/// outline with its own fill, stroke and text. `deckmonkey scene export` writes one from a deck;
/// `deckmonkey scene build` makes a deck from one, copying Keynote-made parts (docs/spec.md §9) and
/// giving each drawable its look as a style variation over the theme's (CLAUDE.md, invariant 6).
public struct Scene: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var slides: [SceneSlide]

    public init(width: Double, height: Double, slides: [SceneSlide]) {
        self.width = width; self.height = height; self.slides = slides
    }
}

public struct SceneSlide: Codable, Sendable, Equatable {
    /// Back to front.
    public var drawables: [SceneDrawable]
    public init(drawables: [SceneDrawable]) { self.drawables = drawables }
}

/// One drawable: an outline in its frame (points, origin at the frame's top left), rotated by
/// `angle` degrees counter-clockwise about the frame's centre.
public struct SceneDrawable: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public var angle: Double
    public var path: [ScenePathElement]
    public var fill: SceneFill?
    public var stroke: SceneStroke?
    public var text: SceneText?
    /// A text box (Keynote's text item) rather than a shape holding text.
    public var textBox: Bool
    /// Mirrored left to right about the frame's centre (outline and fill; text stays readable).
    public var flipped: Bool
    /// The width (height) follows the text: `width` (`height`) is only its last laid-out size,
    /// and the frame grows from the edge its alignment names.
    public var autoWidth: Bool, autoHeight: Bool

    public init(x: Double, y: Double, width: Double, height: Double, angle: Double = 0, path: [ScenePathElement],
                fill: SceneFill? = nil, stroke: SceneStroke? = nil, text: SceneText? = nil, textBox: Bool = false, flipped: Bool = false,
                autoWidth: Bool = false, autoHeight: Bool = false) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.angle = angle
        self.path = path; self.fill = fill; self.stroke = stroke; self.text = text; self.textBox = textBox; self.flipped = flipped
        self.autoWidth = autoWidth; self.autoHeight = autoHeight
    }

    enum CodingKeys: String, CodingKey { case x, y, width, height, angle, path, fill, stroke, text, textBox, flipped, autoWidth, autoHeight }

    /// `angle` and the flags may be left out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width); height = try c.decode(Double.self, forKey: .height)
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        path = try c.decode([ScenePathElement].self, forKey: .path)
        fill = try c.decodeIfPresent(SceneFill.self, forKey: .fill)
        stroke = try c.decodeIfPresent(SceneStroke.self, forKey: .stroke)
        text = try c.decodeIfPresent(SceneText.self, forKey: .text)
        textBox = try c.decodeIfPresent(Bool.self, forKey: .textBox) ?? false
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        autoWidth = try c.decodeIfPresent(Bool.self, forKey: .autoWidth) ?? false
        autoHeight = try c.decodeIfPresent(Bool.self, forKey: .autoHeight) ?? false
    }

    /// An open path is a line: it takes the theme's line style, a closed one its shape style.
    public var isOpen: Bool { !path.contains { $0.op == .close } }
}

public struct ScenePathElement: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable { case move = "M", line = "L", curve = "C", close = "Z" }
    public var op: Op
    /// x, y pairs: one for move and line, three for a curve (two controls and the end).
    public var points: [Double]
    public init(_ op: Op, _ points: [Double] = []) { self.op = op; self.points = points }
}

/// A colour is `#rrggbb` or `#rrggbbaa` (sRGB), or exactly, in CSS's syntax,
/// `color(srgb r g b)` or `color(display-p3 r g b / a)` (components 0…1).
public struct SceneFill: Codable, Sendable, Equatable {
    public var color: String?
    public var gradient: SceneGradient?
    public init(color: String? = nil, gradient: SceneGradient? = nil) { self.color = color; self.gradient = gradient }
}

public struct SceneGradient: Codable, Sendable, Equatable {
    public struct Stop: Codable, Sendable, Equatable {
        public var color: String
        public var fraction: Double
        public init(color: String, fraction: Double) { self.color = color; self.fraction = fraction }
    }
    public var radial: Bool
    public var stops: [Stop]
    /// Radians, counter-clockwise from +x, as Keynote stores it (a linear gradient's direction).
    public var angle: Double
    public init(radial: Bool = false, stops: [Stop], angle: Double) { self.radial = radial; self.stops = stops; self.angle = angle }
}

public struct SceneStroke: Codable, Sendable, Equatable {
    public var color: String
    public var width: Double
    public init(color: String, width: Double) { self.color = color; self.width = width }
}

public struct SceneText: Codable, Sendable, Equatable {
    public enum Alignment: String, Codable, Sendable { case left, center, right, justified, natural }
    public enum VerticalAlignment: String, Codable, Sendable { case top, middle, bottom }
    public var paragraphs: [SceneParagraph]
    public var verticalAlignment: VerticalAlignment
    /// Left, top, right, bottom insets in points.
    public var padding: [Double]
    public init(paragraphs: [SceneParagraph], verticalAlignment: VerticalAlignment = .top, padding: [Double] = [4, 4, 4, 4]) {
        self.paragraphs = paragraphs; self.verticalAlignment = verticalAlignment; self.padding = padding
    }
}

public struct SceneParagraph: Codable, Sendable, Equatable {
    public var text: String
    /// A PostScript name.
    public var font: String
    public var size: Double
    public var color: String
    public var alignment: SceneText.Alignment
    /// The slide's number in place of `text` (a slide-number field).
    public var slideNumber: Bool
    public init(text: String, font: String, size: Double, color: String, alignment: SceneText.Alignment = .natural, slideNumber: Bool = false) {
        self.text = text; self.font = font; self.size = size; self.color = color; self.alignment = alignment; self.slideNumber = slideNumber
    }
}
