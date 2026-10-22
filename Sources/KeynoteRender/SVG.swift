import Foundation
import IWASchema

/// Deterministic SVG text: numbers with at most three decimals and no trailing zeros, escaped
/// strings, and a definitions block whose identifiers count up from 1 in emission order, so the
/// same slide always renders to the same bytes.
enum SVG {
    static func n(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
        var s = String(format: "%.3f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func n(_ value: Float) -> String { n(Double(value)) }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // XML 1.0 forbids most C0 controls; Keynote's text uses some as markers.
            case _ where scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r": continue
            case "\u{FFFE}", "\u{FFFF}": continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// An sRGB colour and its alpha, from any of Keynote's colour models.
    struct RGBA: Equatable {
        var r: Double, g: Double, b: Double, a: Double

        init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }

        init(_ color: TSP_Color) {
            let a = color.hasA ? Double(color.a) : 1
            switch color.model {
            case .cmyk:
                let k = Double(color.k)
                self.init(r: (1 - Double(color.c)) * (1 - k), g: (1 - Double(color.m)) * (1 - k), b: (1 - Double(color.y)) * (1 - k), a: a)
            case .white:
                let w = Double(color.w)
                self.init(r: w, g: w, b: w, a: a)
            default:
                let r = Double(color.r), g = Double(color.g), b = Double(color.b)
                if color.hasRgbspace, color.rgbspace == .p3 {
                    let s = Self.sRGB(fromDisplayP3: (r, g, b))
                    self.init(r: s.r, g: s.g, b: s.b, a: a)
                } else {
                    self.init(r: r, g: g, b: b, a: a)
                }
            }
        }

        /// Display P3 to sRGB: both use the sRGB transfer curve, so linearise, change primaries
        /// (P3 D65 to sRGB D65), re-encode; colours outside sRGB are clipped.
        static func sRGB(fromDisplayP3 c: (Double, Double, Double)) -> (r: Double, g: Double, b: Double) {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            func encoded(_ v: Double) -> Double {
                let v = min(1, max(0, v))
                return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
            }
            let (r, g, b) = (linear(c.0), linear(c.1), linear(c.2))
            return (encoded(1.2249401 * r - 0.2249404 * g),
                    encoded(-0.0420569 * r + 1.0420571 * g),
                    encoded(-0.0196376 * r - 0.0786361 * g + 1.0982735 * b))
        }

        /// `#rrggbb`; the alpha goes in a separate opacity attribute.
        var hex: String {
            func byte(_ v: Double) -> String {
                let b = Int((min(max(v, 0), 1) * 255).rounded())
                return String(format: "%02x", b)
            }
            return "#" + byte(r) + byte(g) + byte(b)
        }
    }

    /// Paint attributes for `fill` or `stroke`: the colour and, below full alpha, its opacity.
    static func paint(_ attribute: String, _ color: RGBA) -> String {
        var s = " \(attribute)=\"\(color.hex)\""
        if color.a < 0.9995 { s += " \(attribute)-opacity=\"\(n(max(0, color.a)))\"" }
        return s
    }
}

/// The `<defs>` of one slide.
struct Definitions {
    private(set) var items: [String] = []
    private var next = 1

    mutating func add(_ make: (String) -> String) -> String {
        let id = "d\(next)"
        next += 1
        items.append(make(id))
        return id
    }

    var markup: String { items.isEmpty ? "" : "<defs>" + items.joined() + "</defs>" }
}
