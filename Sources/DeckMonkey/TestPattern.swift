import Foundation
import KeynoteGraph

/// A display test pattern at any resolution, as a `Scene` (Jay's 4K Test Pattern, generalised):
/// a one-unit grid with heavier centre lines and corner-to-corner diagonals, seven colour bars,
/// resolution wedges (1-point lines at a 3-point pitch, so at the slide's own size they are one
/// device pixel on, two off), a centred circle, two rows of grey steps, two gradient "1" boxes, the
/// title and the resolution. The unit is a 27th of the height, rounded; at 3840 × 2160 it is 80
/// points and every element sits where the original's does, give or take the original's hand
/// placement. One slide per title.
public struct TestPattern: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var titles: [String]
    /// Small print at the bottom right (none when nil).
    public var credit: String?

    public init(width: Int, height: Int, titles: [String] = ["Keynote"], credit: String? = nil) {
        self.width = width; self.height = height; self.titles = titles; self.credit = credit
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case tooSmall(width: Int, height: Int)
        case noTitles

        public var description: String {
            switch self {
            case .tooSmall(let w, let h): return "\(w)x\(h) is too small for a test pattern (at least 320x240, no taller than wide)"
            case .noTitles: return "a test pattern needs at least one title (one slide each)"
            }
        }
    }

    // The original's colours, exactly as Keynote stored them.
    static let white = "color(srgb 0.9999388 0.99999994 0.999878)"
    static let textWhite = "color(srgb 0.9999966 0.99999994 0.99999994)"
    static let black = "color(srgb 0 0 0)"
    static let bars = [
        white,
        "color(display-p3 0.83677787 0.8220064 0.2665814)",    // yellow
        "color(display-p3 0.37865064 0.8193146 0.8274814)",    // cyan
        "color(display-p3 0.37582746 0.81403744 0.24306126)",  // green
        "color(display-p3 0.7767552 0.2629833 0.8118301)",     // magenta
        "color(display-p3 0.777951 0.20618375 0.11769754)",    // red
        "color(display-p3 0.055738512 0.1596833 0.8079171)",   // blue
    ]
    static let gradientTop = "color(display-p3 0.9921645 0.9921459 0.99215853)"
    static let gradientBottom = "color(display-p3 0.5804532 0.58044195 0.5804496)"
    /// Grey steps: lightness 0.95 … 0.05, labelled with their ink percentage.
    static let steps: [(level: Double, label: String)] = [
        (0.95, "5"), (0.9, "10"), (0.8, "20"), (0.7, "30"), (0.6, "40"), (0.5, "50"),
        (0.4, "60"), (0.3, "70"), (0.2, "80"), (0.1, "90"), (0.05, "95"),
    ]

    public func scene() throws -> Scene {
        guard width >= 320, height >= 240, height <= width else { throw Failure.tooSmall(width: width, height: height) }
        guard !titles.isEmpty else { throw Failure.noTitles }
        return Scene(width: Double(width), height: Double(height), slides: titles.map { SceneSlide(drawables: drawables(title: $0)) })
    }

    func drawables(title: String) -> [SceneDrawable] {
        let W = Double(width), H = Double(height)
        let u = (H / 27).rounded()
        let cx = (W / 2).rounded()
        func at(_ v: Double) -> Double { (v * u).rounded() }
        var out = [SceneDrawable]()

        // Grid: verticals out from the centre, horizontals down from the top; the far edges one
        // point in, so they are on the page. Thirds, diagonals and a heavier centre over it.
        out.append(Self.line(W / 3, 0, W / 3, H, width: 1))
        out.append(Self.line(2 * W / 3, 0, 2 * W / 3, H, width: 1))
        out.append(Self.line(0, 0, W, H, width: 2))
        out.append(Self.line(0, H, W, 0, width: 2))
        var columns = Set<Double>([0, W - 1])
        var x = cx
        while x > 0 { columns.insert(x); x -= u }
        x = cx + u
        while x < W - 1 { columns.insert(x); x += u }
        for x in columns.sorted() where x != cx { out.append(Self.line(x, 0, x, H, width: 1)) }
        out.append(Self.line(cx, 0, cx, H, width: 3))
        var y = 0.0
        while y < H - 1 { out.append(Self.line(0, y, W, y, width: 1)); y += u }
        out.append(Self.line(0, H - 1, W, H - 1, width: 1))

        // Resolution wedges: black boxes over the grid, filled with 1-point lines every 3 points
        // (horizontal at the sides, vertical in the middle).
        let side = (w: at(2.5), h: at(14.25), x: at(4.1875), y: at(6.375))
        let sides = [side.x, W - side.x - side.w]
        let middle = (w: at(21.25), h: at(5), y: at(13.75))
        let middleX = cx - (middle.w / 2).rounded()
        for sx in sides { out.append(Self.box(sx, side.y, side.w, side.h, fill: Self.black)) }
        out.append(Self.box(middleX, middle.y, middle.w, middle.h, fill: Self.black))
        var wy = side.y + 1
        while wy < side.y + side.h - 1 {
            for sx in sides { out.append(Self.line(sx + 1, wy, sx + side.w + 1, wy, width: 1)) }
            wy += 3
        }
        var wx = middleX + 3
        while wx < middleX + middle.w - 1 { out.append(Self.line(wx, middle.y + 1, wx, middle.y + middle.h + 1, width: 1)); wx += 3 }

        // Colour bars, centred.
        let bar = (w: at(2.5), h: at(8.125), y: at(4.5))
        let barsX = cx - (Double(Self.bars.count) * bar.w / 2).rounded()
        for (i, color) in Self.bars.enumerated() { out.append(Self.box(barsX + Double(i) * bar.w, bar.y, bar.w, bar.h, fill: color)) }

        // Gradient "1" boxes in two opposite corners, over the side wedges' columns.
        let one = (w: side.w, h: at(2.4), y: at(2.35))
        let gradient = SceneFill(gradient: SceneGradient(stops: [.init(color: Self.gradientTop, fraction: 0), .init(color: Self.gradientBottom, fraction: 1)],
                                                         angle: 3 * .pi / 2))
        func oneBox(_ x: Double, _ y: Double) -> SceneDrawable {
            var d = Self.box(x, y, one.w, one.h, fill: nil)
            d.fill = gradient
            d.text = SceneText(paragraphs: [SceneParagraph(text: "1", font: "Helvetica", size: at(2), color: Self.black, alignment: .center)],
                               verticalAlignment: .middle, padding: [0, 0, 0, 0])
            return d
        }
        out.append(oneBox(sides[0], one.y))

        // The title, right-aligned over the right wedge, level with the top "1"; the resolution,
        // left-aligned over the left wedge, near the bottom.
        let label = (w: at(16), h: at(2.4), size: at(1.8))
        out.append(Self.textBox(sides[1] + side.w - label.w, one.y, label.w, label.h, title, font: "Helvetica", size: label.size, alignment: .right))
        out.append(Self.textBox(side.x, H - at(3.7), label.w, label.h, "\(width)x\(height)", font: "Helvetica", size: label.size, alignment: .left))

        // The circle, centred, nearly the page's height.
        out.append(Self.circle(cx: cx, cy: (H / 2).rounded(), diameter: at(25.5), width: 2))
        if let credit {
            let size = max(6, (u * 0.1125).rounded())
            out.append(Self.textBox(W - at(8.25), H - size * 1.5 - at(0.125), at(8), size * 1.5, credit, font: "Helvetica", size: size, alignment: .right))
        }

        // Grey steps on rows 22 and 23: labelled light to dark, and dark to light above.
        let stepsX = cx - at(Double(Self.steps.count) / 2)
        for (i, step) in Self.steps.enumerated() {
            var d = Self.box(stepsX + Double(i) * u, at(23), u, u, fill: Self.grey(step.level))
            d.text = SceneText(paragraphs: [SceneParagraph(text: step.label, font: "HelveticaNeue-Medium", size: at(0.3),
                                                           color: step.level > 0.55 ? Self.black : Self.textWhite, alignment: .center)],
                               verticalAlignment: .middle, padding: [0, 0, 0, 0])
            out.append(d)
        }
        for (i, step) in Self.steps.reversed().enumerated() { out.append(Self.box(stepsX + Double(i) * u, at(22), u, u, fill: Self.grey(step.level))) }
        out.append(oneBox(W - sides[0] - one.w, H - one.y - one.h))
        return out
    }

    static func grey(_ level: Double) -> String { "color(srgb \(level) \(level) \(level))" }

    /// A line as Keynote stores one: a horizontal outline its length long, turned about its
    /// midpoint (degrees counter-clockwise, y down).
    static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, width: Double) -> SceneDrawable {
        let dx = x2 - x1, dy = y2 - y1
        let length = (dx * dx + dy * dy).squareRoot()
        var angle = -atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        return SceneDrawable(x: (x1 + x2) / 2 - length / 2, y: (y1 + y2) / 2, width: length, height: 0, angle: angle,
                             path: [.init(.move, [0, 0]), .init(.line, [length, 0])], stroke: SceneStroke(color: white, width: width))
    }

    static func rectangle(_ w: Double, _ h: Double) -> [ScenePathElement] {
        [.init(.move, [0, 0]), .init(.line, [w, 0]), .init(.line, [w, h]), .init(.line, [0, h]), .init(.close)]
    }

    static func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, fill: String?) -> SceneDrawable {
        SceneDrawable(x: x, y: y, width: w, height: h, path: rectangle(w, h), fill: fill.map { SceneFill(color: $0) })
    }

    static func textBox(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ text: String, font: String, size: Double,
                        alignment: SceneText.Alignment) -> SceneDrawable {
        SceneDrawable(x: x, y: y, width: w, height: h, path: rectangle(w, h),
                      text: SceneText(paragraphs: [SceneParagraph(text: text, font: font, size: size, color: textWhite, alignment: alignment)],
                                      verticalAlignment: .middle, padding: [0, 0, 0, 0]),
                      textBox: true)
    }

    /// A circle from four cubic quarters, starting at the top.
    static func circle(cx: Double, cy: Double, diameter: Double, width: Double) -> SceneDrawable {
        let r = diameter / 2, k = 0.5522847498 * r
        let path: [ScenePathElement] = [
            .init(.move, [r, 0]),
            .init(.curve, [r + k, 0, 2 * r, r - k, 2 * r, r]),
            .init(.curve, [2 * r, r + k, r + k, 2 * r, r, 2 * r]),
            .init(.curve, [r - k, 2 * r, 0, r + k, 0, r]),
            .init(.curve, [0, r - k, r - k, 0, r, 0]),
            .init(.close),
        ]
        return SceneDrawable(x: cx - r, y: cy - r, width: diameter, height: diameter, path: path, stroke: SceneStroke(color: white, width: width))
    }
}
