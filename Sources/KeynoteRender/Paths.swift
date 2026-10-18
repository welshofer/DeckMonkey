import Foundation
import IWASchema

/// A shape's outline in its natural-size coordinates. It is scaled onto the drawable's frame
/// numerically, not with an SVG transform, so a stroke keeps its own width.
struct Outline {
    enum Command {
        case move(Double, Double), line(Double, Double)
        case quad(Double, Double, Double, Double)
        case cubic(Double, Double, Double, Double, Double, Double)
        case close
    }

    var commands: [Command]
    var width: Double, height: Double

    var closed: Bool { commands.contains { if case .close = $0 { return true }; return false } }

    /// Path data with x scaled by `sx` and y by `sy`.
    func d(sx: Double = 1, sy: Double = 1) -> String {
        func p(_ x: Double, _ y: Double) -> String { "\(SVG.n(x * sx)) \(SVG.n(y * sy))" }
        var out = ""
        for c in commands {
            switch c {
            case let .move(x, y): out += "M" + p(x, y)
            case let .line(x, y): out += "L" + p(x, y)
            case let .quad(a, b, x, y): out += "Q" + p(a, b) + " " + p(x, y)
            case let .cubic(a, b, c, d, x, y): out += "C" + p(a, b) + " " + p(c, d) + " " + p(x, y)
            case .close: out += "Z"
            }
        }
        return out
    }

    /// The horizontal room inside a closed outline for text, in natural coordinates: the span
    /// inside it at every height through its middle half. A callout's tail beside its body adds
    /// nothing (Keynote centres the words in the body); a rectangle gives its whole width.
    var textSpan: (x0: Double, x1: Double)? {
        guard closed, width > 0, height > 0 else { return nil }
        // Flatten to segments; curves in eight steps.
        var segments = [((Double, Double), (Double, Double))]()
        var start = (0.0, 0.0), current = (0.0, 0.0)
        for c in commands.prefix(4_096) {
            switch c {
            case let .move(x, y): start = (x, y); current = start
            case let .line(x, y): segments.append((current, (x, y))); current = (x, y)
            case let .quad(a, b, x, y):
                for k in 1...8 {
                    let t = Double(k) / 8, u = 1 - t
                    let q = (u * u * current.0 + 2 * u * t * a + t * t * x, u * u * current.1 + 2 * u * t * b + t * t * y)
                    segments.append((k == 1 ? current : segments[segments.count - 1].1, q))
                }
                current = (x, y)
            case let .cubic(a, b, c2, d, x, y):
                let p0 = current
                for k in 1...8 {
                    let t = Double(k) / 8, u = 1 - t
                    let q = (u * u * u * p0.0 + 3 * u * u * t * a + 3 * u * t * t * c2 + t * t * t * x,
                             u * u * u * p0.1 + 3 * u * u * t * b + 3 * u * t * t * d + t * t * t * y)
                    segments.append((k == 1 ? p0 : segments[segments.count - 1].1, q))
                }
                current = (x, y)
            case .close: segments.append((current, start)); current = start
            }
        }
        let ys = segments.flatMap { [$0.0.1, $0.1.1] }
        guard let minY = ys.min(), let maxY = ys.max(), maxY > minY else { return nil }
        var lo = -Double.infinity, hi = Double.infinity
        for k in 0...8 {
            let y = minY + (maxY - minY) * (0.25 + 0.5 * Double(k) / 8)
            var crossings = [Double]()
            for (a, b) in segments where (a.1 <= y) != (b.1 <= y) {
                crossings.append(a.0 + (y - a.1) / (b.1 - a.1) * (b.0 - a.0))
            }
            // The outer span at this height: a tail drawn as its own subpath over the body
            // would split the body under even-odd filling.
            guard let first = crossings.min(), let last = crossings.max(), crossings.count >= 2 else { return nil }
            lo = max(lo, first); hi = min(hi, last)
        }
        // In the outline's own coordinates, as it is drawn (a callout's tail may lie outside
        // its natural size).
        lo = max(lo, 0); hi = min(hi, width)
        guard hi > lo else { return nil }
        return (lo, hi)
    }

    /// The outline's two end points and the directions it leaves and arrives in, for line ends.
    var ends: (start: (Double, Double), startToward: (Double, Double), end: (Double, Double), endFrom: (Double, Double))? {
        var points = [(Double, Double)]()
        for c in commands {
            switch c {
            case let .move(x, y), let .line(x, y): points.append((x, y))
            case let .quad(a, b, x, y): points += [(a, b), (x, y)]
            case let .cubic(a, b, c, d, x, y): points += [(a, b), (c, d), (x, y)]
            case .close: break
            }
        }
        guard points.count >= 2 else { return nil }
        let s = points[0], e = points[points.count - 1]
        let toward = points.dropFirst().first { $0 != s } ?? e
        let from = points.dropLast().last { $0 != e } ?? s
        return (s, toward, e, from)
    }
}

enum Paths {
    /// The outline a path source describes, or nil for a kind this renderer cannot draw.
    static func outline(_ source: TSD_PathSourceArchive) -> Outline? {
        if source.hasBezierPathSource { return bezier(source.bezierPathSource) }
        if source.hasConnectionLinePathSource { return bezier(source.connectionLinePathSource.super) }
        if source.hasEditableBezierPathSource { return editable(source.editableBezierPathSource) }
        if source.hasScalarPathSource { return scalar(source.scalarPathSource) }
        if source.hasPointPathSource { return point(source.pointPathSource) }
        if source.hasCalloutPathSource { return callout(source.calloutPathSource) }
        return nil
    }

    static func size(_ s: TSP_Size) -> (Double, Double) { (Double(s.width), Double(s.height)) }

    static func commands(_ p: TSP_Path) -> [Outline.Command] {
        var out = [Outline.Command]()
        for e in p.elements {
            let q = e.points.map { (Double($0.x), Double($0.y)) }
            switch e.type {
            case .moveTo where q.count >= 1: out.append(.move(q[0].0, q[0].1))
            case .lineTo where q.count >= 1: out.append(.line(q[0].0, q[0].1))
            case .quadCurveTo where q.count >= 2: out.append(.quad(q[0].0, q[0].1, q[1].0, q[1].1))
            case .curveTo where q.count >= 3: out.append(.cubic(q[0].0, q[0].1, q[1].0, q[1].1, q[2].0, q[2].1))
            case .closeSubpath: out.append(.close)
            default: break
            }
        }
        // Keynote ends a closed outline with a stray moveTo; it draws nothing.
        while let last = out.last, case .move = last { out.removeLast() }
        return out
    }

    /// A bezier outline is drawn by mapping the path's own bounds onto the frame: Keynote stores a
    /// mask as a 100 × 100 square with a natural size of 860 × 880, so the natural size is not the
    /// path's coordinate space.
    static func bezier(_ b: TSD_BezierPathSourceArchive) -> Outline? {
        guard b.hasPath else { return nil }
        return fitted(commands(b.path), fallback: size(b.naturalSize))
    }

    /// `commands` moved so their bounds start at the origin, with those bounds as the size; an
    /// axis with no extent (a straight line) keeps its coordinates and the fallback size.
    static func fitted(_ commands: [Outline.Command], fallback: (Double, Double)) -> Outline {
        var xs = [Double](), ys = [Double]()
        for c in commands {
            switch c {
            case let .move(x, y), let .line(x, y): xs.append(x); ys.append(y)
            case let .quad(a, b, x, y): xs += [a, x]; ys += [b, y]
            case let .cubic(a, b, c, d, x, y): xs += [a, c, x]; ys += [b, d, y]
            case .close: break
            }
        }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return Outline(commands: commands, width: fallback.0, height: fallback.1)
        }
        let useX = maxX - minX > 1e-6, useY = maxY - minY > 1e-6
        let dx = useX ? minX : 0, dy = useY ? minY : 0
        let moved = commands.map { c -> Outline.Command in
            switch c {
            case let .move(x, y): return .move(x - dx, y - dy)
            case let .line(x, y): return .line(x - dx, y - dy)
            case let .quad(a, b, x, y): return .quad(a - dx, b - dy, x - dx, y - dy)
            case let .cubic(a, b, c, d, x, y): return .cubic(a - dx, b - dy, c - dx, d - dy, x - dx, y - dy)
            case .close: return .close
            }
        }
        return Outline(commands: moved, width: useX ? maxX - minX : fallback.0, height: useY ? maxY - minY : fallback.1)
    }

    static func editable(_ e: TSD_EditableBezierPathSourceArchive) -> Outline? {
        var out = [Outline.Command]()
        for sub in e.subpaths where !sub.nodes.isEmpty {
            let n = sub.nodes
            out.append(.move(Double(n[0].nodePoint.x), Double(n[0].nodePoint.y)))
            let segments = sub.closed ? n.count : n.count - 1
            for i in 0..<max(0, segments) {
                let a = n[i], b = n[(i + 1) % n.count]
                out.append(.cubic(Double(a.outControlPoint.x), Double(a.outControlPoint.y), Double(b.inControlPoint.x),
                                  Double(b.inControlPoint.y), Double(b.nodePoint.x), Double(b.nodePoint.y)))
            }
            if sub.closed { out.append(.close) }
        }
        return out.isEmpty ? nil : fitted(out, fallback: size(e.naturalSize))
    }

    static func rect(_ w: Double, _ h: Double, radius: Double) -> [Outline.Command] {
        let r = max(0, min(radius, w / 2, h / 2))
        guard r > 0 else { return [.move(0, 0), .line(w, 0), .line(w, h), .line(0, h), .close] }
        // A circular corner as a cubic: control points at 0.5523 of the radius.
        let k = r * (1 - 0.5522847498)
        return [.move(r, 0), .line(w - r, 0), .cubic(w - k, 0, w, k, w, r), .line(w, h - r), .cubic(w, h - k, w - k, h, w - r, h),
                .line(r, h), .cubic(k, h, 0, h - k, 0, h - r), .line(0, r), .cubic(0, k, k, 0, r, 0), .close]
    }

    static func polygon(_ points: [(Double, Double)]) -> [Outline.Command] {
        guard let first = points.first else { return [] }
        return [.move(first.0, first.1)] + points.dropFirst().map { .line($0.0, $0.1) } + [.close]
    }

    static func scalar(_ s: TSD_ScalarPathSourceArchive) -> Outline? {
        let (w, h) = size(s.naturalSize)
        let v = Double(s.scalar)
        switch s.type {
        case .kTsdroundedRectangle:
            return Outline(commands: rect(w, h, radius: v), width: w, height: h)
        case .kTsdregularPolygon:
            let sides = max(3, min(Int(v.rounded()), 360))
            let pts = (0..<sides).map { i -> (Double, Double) in
                let a = -Double.pi / 2 + Double(i) * 2 * .pi / Double(sides)
                return (w / 2 + cos(a) * w / 2, h / 2 + sin(a) * h / 2)
            }
            return Outline(commands: polygon(pts), width: w, height: h)
        case .kTsdchevron:
            let x = max(0, min(v, w))
            return Outline(commands: polygon([(0, 0), (w - x, 0), (w, h / 2), (w - x, h), (0, h), (x, h / 2)]), width: w, height: h)
        }
    }

    static func point(_ p: TSD_PointPathSourceArchive) -> Outline? {
        let (w, h) = size(p.naturalSize)
        let px = Double(p.point.x), py = Double(p.point.y)
        let pts: [(Double, Double)]
        switch p.type {
        case .kTsdrightSingleArrow:
            pts = [(0, py), (px, py), (px, 0), (w, h / 2), (px, h), (px, h - py), (0, h - py)]
        case .kTsdleftSingleArrow:
            pts = [(w, py), (px, py), (px, 0), (0, h / 2), (px, h), (px, h - py), (w, h - py)]
        case .kTsddoubleArrow:
            pts = [(0, h / 2), (px, 0), (px, py), (w - px, py), (w - px, 0), (w, h / 2), (w - px, h), (w - px, h - py), (px, h - py), (px, h)]
        case .kTsdstar:
            let count = max(3, min(Int(px.rounded()), 360)), inner = max(0, min(py, 1))
            pts = (0..<(2 * count)).map { i -> (Double, Double) in
                let a = -Double.pi / 2 + Double(i) * .pi / Double(count)
                let r = i % 2 == 0 ? 1 : inner
                return (w / 2 + cos(a) * w / 2 * r, h / 2 + sin(a) * h / 2 * r)
            }
        case .kTsdplus:
            let x = max(0, min(px, w / 2)), y = max(0, min(py, h / 2))
            pts = [(x, 0), (w - x, 0), (w - x, y), (w, y), (w, h - y), (w - x, h - y), (w - x, h), (x, h), (x, h - y), (0, h - y), (0, y), (x, y)]
        }
        return Outline(commands: polygon(pts), width: w, height: h)
    }

    static func callout(_ c: TSD_CalloutPathSourceArchive) -> Outline? {
        let (w, h) = size(c.naturalSize)
        let tip = (Double(c.tailPosition.x), Double(c.tailPosition.y))
        // The tail stands on the edge facing its tip, `tail_size` either side of the point
        // nearest the tip (or of the edge's middle, centred), half a point inside the body so
        // the two fill as one. It winds as the body does, or nonzero filling would cut it out.
        let half = max(1, Double(c.tailSize)), r = Double(c.cornerRadius)
        func along(_ v: Double, _ length: Double) -> Double {
            let lo = min(r + half, length / 2), hi = max(length - r - half, length / 2)
            return c.centerTail ? length / 2 : min(max(v, lo), hi)
        }
        var triangle: [(Double, Double)]
        if tip.1 > h {
            let x = along(tip.0, w); triangle = [(x - half, h - 0.5), tip, (x + half, h - 0.5)]
        } else if tip.1 < 0 {
            let x = along(tip.0, w); triangle = [(x - half, 0.5), tip, (x + half, 0.5)]
        } else if tip.0 < 0 {
            let y = along(tip.1, h); triangle = [(0.5, y - half), tip, (0.5, y + half)]
        } else {
            let y = along(tip.1, h); triangle = [(w - 0.5, y - half), tip, (w - 0.5, y + half)]
        }
        let area = (0..<3).reduce(0.0) { $0 + triangle[$1].0 * triangle[($1 + 1) % 3].1 - triangle[($1 + 1) % 3].0 * triangle[$1].1 }
        if area < 0 { triangle.reverse() }
        return Outline(commands: rect(w, h, radius: r) + polygon(triangle), width: w, height: h)
    }
}
