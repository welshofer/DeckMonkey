import Foundation
import Testing
@testable import DeckMonkey
import KeynoteGraph
import KeynoteRender

/// Scene build: a hand-written scene with each kind of drawable the 4K test pattern needs (a P3
/// fill, a line, a flipped gradient, a circle, a text box that grows to its text) becomes a deck
/// that validates and exports back as the same scene.
@Suite("Scene build")
struct SceneBuildTests {
    static let template = DeckIRWriterTests.root.appendingPathComponent("Corpus/templates/black_wide.key")

    static let scene: Scene = {
        let rect: [ScenePathElement] = [.init(.move, [0, 0]), .init(.line, [200, 0]), .init(.line, [200, 100]), .init(.line, [0, 100]), .init(.close)]
        // An ellipse filling its frame (control points binary-exact, so they survive Float).
        let circle: [ScenePathElement] = [
            .init(.move, [100, 0]), .init(.curve, [155.25, 0, 200, 22.375, 200, 50]), .init(.curve, [200, 77.625, 155.25, 100, 100, 100]),
            .init(.curve, [44.75, 100, 0, 77.625, 0, 50]), .init(.curve, [0, 22.375, 44.75, 0, 100, 0]), .init(.close),
        ]
        let p3 = "color(display-p3 0.75 0.25 0.8125)"
        return Scene(width: 3840, height: 2160, slides: [
            SceneSlide(drawables: [
                SceneDrawable(x: 100, y: 100, width: 200, height: 100, path: rect, fill: SceneFill(color: p3)),
                SceneDrawable(x: 400, y: 100, width: 200, height: 100, path: rect, fill: SceneFill(color: p3)),
                SceneDrawable(x: 0, y: 1080, width: 3840, height: 0, path: [.init(.move, [0, 0]), .init(.line, [3840, 0])],
                              stroke: SceneStroke(color: "color(srgb 1 1 1)", width: 1)),
                SceneDrawable(x: 700, y: 100, width: 200, height: 100, path: rect,
                              fill: SceneFill(gradient: SceneGradient(stops: [.init(color: "color(srgb 1 1 1)", fraction: 0), .init(color: "color(srgb 0.5 0.5 0.5)", fraction: 1)], angle: Double(-Float.pi / 2))),
                              stroke: SceneStroke(color: "color(srgb 0 0 0)", width: 2), flipped: true),
                SceneDrawable(x: 1000, y: 100, width: 200, height: 100, path: circle, stroke: SceneStroke(color: "color(srgb 1 1 1)", width: 2)),
            ]),
            SceneSlide(drawables: [
                SceneDrawable(x: 500, y: 1800, width: 545.5, height: 189, path: rect.map { e in .init(e.op, e.points.enumerated().map { $0.offset % 2 == 0 ? $0.element * 545.5 / 200 : $0.element * 189 / 100 }) },
                              text: SceneText(paragraphs: [SceneParagraph(text: "3840x2160", font: "Helvetica-Bold", size: 144, color: "color(srgb 1 1 1)", alignment: .left)]),
                              textBox: true, autoWidth: true, autoHeight: true),
                SceneDrawable(x: 100, y: 400, width: 200, height: 100, path: rect, fill: SceneFill(color: "color(srgb 0.5 0.5 0.5)"),
                              text: SceneText(paragraphs: [SceneParagraph(text: "50", font: "HelveticaNeue-Medium", size: 24, color: "color(srgb 0 0 0)", alignment: .center)],
                                              verticalAlignment: .middle, padding: [2, 2, 2, 2])),
            ]),
        ])
    }()

    @Test("a scene builds, validates, and exports back unchanged", .enabled(if: FileManager.default.fileExists(atPath: template.path), "no Corpus/templates"))
    func roundTrip() throws {
        var document = try KeynoteDocument.open(Self.template)
        let report = try document.build(Self.scene)
        #expect(report.drawables == 7)
        // Six shape variations (the two P3 rectangles share one) and two paragraph variations.
        #expect(report.styles == 8, "\(report.styles)")
        let reopened = try KeynoteDocument.open(IWAPackage.openZip(document.serializedData()))
        #expect(reopened.validate().filter { $0.severity == .error }.isEmpty)
        let exported = KeynoteRenderer(document: reopened).scene().scene
        #expect(exported.width == 3840 && exported.height == 2160)
        try #require(exported.slides.count == Self.scene.slides.count)
        for (built, wanted) in zip(exported.slides, Self.scene.slides) {
            // The master's own drawables come first.
            let own = Array(built.drawables.suffix(wanted.drawables.count))
            for (b, w) in zip(own, wanted.drawables) {
                #expect(b == w)
                if b != w, let got = try? JSONEncoder().encode(b), let want = try? JSONEncoder().encode(w) {
                    print("got  ", String(decoding: got, as: UTF8.self)); print("want ", String(decoding: want, as: UTF8.self))
                }
            }
        }
    }

    @Test("colours parse exactly, in sRGB and Display P3")
    func colours() throws {
        let p3 = try KeynoteDocument.sceneColor("color(display-p3 0.7767552 0.2629833 0.8118301)")
        #expect(p3.rgbspace == .p3 && p3.r == 0.7767552 && p3.a == 1)
        let translucent = try KeynoteDocument.sceneColor("color(srgb 1 0 0 / 0.5)")
        #expect(translucent.rgbspace == .srgb && translucent.a == 0.5)
        #expect(try KeynoteDocument.sceneColor("#ff000080").a == Float(0x80) / 255)
        #expect(throws: KeynoteDocument.SceneBuildFailure.self) { try KeynoteDocument.sceneColor("color(lab 50 0 0)") }
    }
}
