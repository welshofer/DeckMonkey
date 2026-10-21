import Foundation
import IWASchema

// DeckMonkey's own stand-ins for Keynote theme artwork a file does not hold (built-in textures and
// photos Keynote supplies itself). They are drawn here from nothing but the file's own data: never
// Apple's artwork, nor anything taken from Keynote's app (CLAUDE.md, "No Apple assets").

extension Canvas {
    /// A paper-like texture: a base colour with a fine grain and a soft vignette. The colour is the
    /// fill's reference colour when the file stores one, else the colour its file name names
    /// (`tile_paper_blue.jpeg`), else a warm neutral.
    /// A tint (Keynote 6 colours a grey paper tile this way) is laid over the base at its alpha.
    mutating func placeholderTexture(name: String?, reference: SVG.RGBA?, tint: SVG.RGBA? = nil, d: String, w: Double, h: Double) -> String {
        var base = reference ?? name.flatMap(Self.namedColour) ?? SVG.RGBA(r: 0.86, g: 0.84, b: 0.80, a: 1)
        if let tint {
            let a = max(0, min(1, tint.a))
            base = SVG.RGBA(r: base.r * (1 - a) + tint.r * a, g: base.g * (1 - a) + tint.g * a, b: base.b * (1 - a) + tint.b * a, a: 1)
        }
        let clip = defs.add { "<clipPath id=\"\($0)\"><path d=\"\(d)\"/></clipPath>" }
        // Grain: fractal noise turned into faint light and dark specks, the same on every render.
        let grain = defs.add { id in
            "<filter id=\"\(id)\" x=\"0\" y=\"0\" width=\"1\" height=\"1\" filterUnits=\"objectBoundingBox\" color-interpolation-filters=\"sRGB\">"
                + "<feTurbulence type=\"fractalNoise\" baseFrequency=\"0.8\" numOctaves=\"3\" seed=\"7\" stitchTiles=\"stitch\"/>"
                + "<feColorMatrix type=\"matrix\" values=\"0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 0 0.5  0 0 0 1.4 -0.55\"/>"
                + "</filter>"
        }
        // A soft light: the base a little lighter in the middle, a little deeper at the edges, in
        // opaque colours (WebKit's PDF capture drops gradient transparency).
        func mix(_ c: SVG.RGBA, _ t: Double, _ k: Double) -> SVG.RGBA {
            SVG.RGBA(r: c.r + (t - c.r) * k, g: c.g + (t - c.g) * k, b: c.b + (t - c.b) * k, a: 1)
        }
        let light = mix(base, 1, 0.08).hex, deep = mix(base, 0, 0.14).hex
        let shade = defs.add { id in
            "<radialGradient id=\"\(id)\" cx=\"0.5\" cy=\"0.45\" r=\"0.75\">"
                + "<stop offset=\"0\" stop-color=\"\(light)\"/><stop offset=\"0.6\" stop-color=\"\(base.hex)\"/>"
                + "<stop offset=\"1\" stop-color=\"\(deep)\"/></radialGradient>"
        }
        return "<g clip-path=\"url(#\(clip))\"><path d=\"\(d)\" fill=\"url(#\(shade))\"/>"
            + "<rect width=\"\(SVG.n(w))\" height=\"\(SVG.n(h))\" filter=\"url(#\(grain))\" opacity=\"0.12\"/></g>"
    }

    /// The colour a texture's file name names, for a theme texture the file does not hold: the
    /// name is the deck's own metadata (Keynote 6's paper tiles are `tile_paper_<colour>`).
    static func namedColour(_ name: String) -> SVG.RGBA? {
        let lower = name.lowercased()
        // Longer names first, so "ltgray" is not read as "gray". Medium grey is set from a deck's
        // export (Music Academy's tinted paper), the rest by eye.
        let colours: [(String, (Double, Double, Double))] = [
            ("ltgray", (0.84, 0.84, 0.82)), ("lightgray", (0.84, 0.84, 0.82)), ("medgray", (0.36, 0.36, 0.35)),
            ("ltbrown", (0.78, 0.68, 0.55)), ("cream", (0.95, 0.92, 0.84)), ("purple", (0.50, 0.38, 0.62)),
            ("orange", (0.91, 0.55, 0.26)), ("yellow", (0.93, 0.78, 0.32)), ("green", (0.38, 0.60, 0.36)),
            ("brown", (0.55, 0.42, 0.30)), ("black", (0.16, 0.16, 0.17)), ("white", (0.96, 0.95, 0.92)),
            ("blue", (0.27, 0.44, 0.66)), ("teal", (0.29, 0.57, 0.59)), ("pink", (0.89, 0.56, 0.64)),
            ("gray", (0.52, 0.52, 0.51)), ("grey", (0.52, 0.52, 0.51)), ("red", (0.77, 0.27, 0.24)),
        ]
        for (word, c) in colours where lower.contains(word) { return SVG.RGBA(r: c.0, g: c.1, b: c.2, a: 1) }
        return nil
    }

    /// The name the file gives a data record (its preferred name; Keynote 6 stores no other).
    func dataName(_ id: UInt64) -> String? {
        guard let info = document.packageMetadata?.datas.first(where: { $0.identifier == id }) else { return nil }
        return info.hasPreferredFileName && !info.preferredFileName.isEmpty ? info.preferredFileName : info.fileName
    }
}
