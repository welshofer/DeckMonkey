// compare.swift — AT-29 (track R): how close DeckMonkey's SVG of each slide is to Keynote's export.
//
// usage: compare <svg-dir> <golden.pdf> <out-dir> [--width 960] [--tolerance 48]
//
// <svg-dir> is `deckmonkey render <deck> -o <svg-dir>`: page-<n>.svg for PDF page n. Each SVG is
// drawn by WebKit (the engine Duo draws previews with: SVG → WKWebView → PDF → pixels) and the
// golden's page n by CoreGraphics, both at --width pixels. A pixel mismatches when any channel
// differs by more than --tolerance (0–255). Writes <out-dir>/page-<n>.png (golden | ours | the
// mismatches in red) and <out-dir>/compare.json, and prints one line per page and the median.
// macOS only; build with `swiftc -O -o .build/compare Scripts/render/compare.swift`.
import AppKit
import PDFKit
import WebKit

struct Options {
    var svgDir: URL, golden: URL, out: URL
    var width = 960, tolerance = 48
}

func parse() -> Options {
    var args = Array(CommandLine.arguments.dropFirst())
    func take(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
    }
    let width = take("--width").flatMap(Int.init) ?? 960
    let tolerance = take("--tolerance").flatMap(Int.init) ?? 48
    guard args.count == 3 else {
        FileHandle.standardError.write("usage: compare <svg-dir> <golden.pdf> <out-dir> [--width 960] [--tolerance 48]\n".data(using: .utf8)!)
        exit(2)
    }
    return Options(svgDir: URL(fileURLWithPath: args[0]), golden: URL(fileURLWithPath: args[1]), out: URL(fileURLWithPath: args[2]),
                   width: width, tolerance: tolerance)
}

/// RGBA8 pixels, premultiplied over white.
struct Bitmap {
    var width: Int, height: Int, pixels: [UInt8]

    init(width: Int, height: Int, draw: (CGContext) -> Void) {
        self.width = width; self.height = height
        pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(ctx)
        }
    }

    var image: CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

func bitmap(page: CGPDFPage, width: Int) -> Bitmap {
    let box = page.getBoxRect(.mediaBox)
    let scale = Double(width) / box.width
    let height = Int((box.height * scale).rounded())
    return Bitmap(width: width, height: height) { ctx in
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
    }
}

@MainActor
final class SVGRasterizer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    var continuation: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    func pdf(svg: String, width: Double, height: Double) async throws -> Data {
        web.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{margin:0;padding:0;width:\(width)px;height:\(height)px;overflow:hidden;background:#fff}svg{display:block;width:\(width)px;height:\(height)px}</style></head><body>\(svg)</body></html>"
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            web.loadHTMLString(html, baseURL: nil)
        }
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        return try await web.pdf(configuration: config)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { continuation?.resume(); continuation = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { continuation?.resume(throwing: error); continuation = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { continuation?.resume(throwing: error); continuation = nil }
    }
}

func viewBox(_ svg: String) -> (Double, Double)? {
    guard let r = svg.range(of: "viewBox=\"") else { return nil }
    let rest = svg[r.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let parts = rest[..<end].split(separator: " ").compactMap { Double($0) }
    return parts.count == 4 ? (parts[2], parts[3]) : nil
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

@MainActor
func run() async {
    let o = parse()
    try? FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    guard let golden = CGPDFDocument(o.golden as CFURL) else { print("error: cannot open \(o.golden.path)"); exit(1) }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: o.svgDir.path)) ?? []
    let pages = files.compactMap { f -> Int? in
        guard f.hasPrefix("page-"), f.hasSuffix(".svg") else { return nil }
        return Int(f.dropFirst(5).dropLast(4))
    }.sorted()
    let rasterizer = SVGRasterizer()
    var results = [[String: Any]]()
    var shares = [Double]()
    for n in pages {
        guard n >= 1, n <= golden.numberOfPages, let page = golden.page(at: n) else {
            print("page \(n): no golden page"); results.append(["page": n, "error": "no golden page"]); continue
        }
        let svg = (try? String(contentsOf: o.svgDir.appendingPathComponent("page-\(n).svg"), encoding: .utf8)) ?? ""
        let reference = bitmap(page: page, width: o.width)
        let (vw, vh) = viewBox(svg) ?? (1920, 1080)
        let ours: Bitmap
        do {
            let data = try await rasterizer.pdf(svg: svg, width: vw, height: vh)
            guard let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!), let p = doc.page(at: 1) else { throw CocoaError(.fileReadCorruptFile) }
            ours = bitmap(page: p, width: o.width)
        } catch {
            print("page \(n): WebKit failed: \(error)"); results.append(["page": n, "error": "\(error)"]); continue
        }
        let h = min(reference.height, ours.height), w = o.width
        var mismatched = 0
        let diff = Bitmap(width: w * 3, height: h) { _ in }
        var composite = diff.pixels
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                var bad = false
                for c in 0..<3 where abs(Int(reference.pixels[i + c]) - Int(ours.pixels[i + c])) > o.tolerance { bad = true }
                if bad { mismatched += 1 }
                let row = y * w * 3
                for c in 0..<4 {
                    composite[(row + x) * 4 + c] = reference.pixels[i + c]
                    composite[(row + w + x) * 4 + c] = ours.pixels[i + c]
                }
                let g = UInt8((Int(reference.pixels[i]) + Int(reference.pixels[i + 1]) + Int(reference.pixels[i + 2])) / 3 / 2 + 127)
                let k = (row + 2 * w + x) * 4
                composite[k] = bad ? 230 : g; composite[k + 1] = bad ? 30 : g; composite[k + 2] = bad ? 30 : g; composite[k + 3] = 255
            }
        }
        var out = diff
        out.pixels = composite
        writePNG(out.image, to: o.out.appendingPathComponent("page-\(n).png"))
        let share = Double(mismatched) / Double(max(1, w * h))
        shares.append(share)
        results.append(["page": n, "mismatch": share])
        print(String(format: "page %d: %.2f%% mismatched", n, share * 100))
    }
    let sorted = shares.sorted()
    let median = sorted.isEmpty ? 0 : sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    let worst = sorted.last ?? 0
    let summary: [String: Any] = ["golden": o.golden.path, "goldenPages": golden.numberOfPages, "pages": results, "median": median, "worst": worst, "width": o.width, "tolerance": o.tolerance]
    if let json = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
        try? json.write(to: o.out.appendingPathComponent("compare.json"))
    }
    print(String(format: "median %.2f%%, worst %.2f%% over %d page(s)", median * 100, worst * 100, shares.count))
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    await run()
    exit(0)
}
app.run()
