import Foundation
import IWAContainer
import IWASchema
import Testing
@testable import KeynoteGraph

/// Moving and resizing drawables. Keynote's own edits of the same objects (Scripts/gate1/geometry.py)
/// are the oracle; these check the stored geometry and the refusals.
@Suite("Drawable geometry")
struct DrawableGeometryTests {
    static let images = CorpusTests.repoRoot.appendingPathComponent("Corpus/features/images.key")
    static let template = CorpusTests.repoRoot.appendingPathComponent("Corpus/templates/basic-white_wide.key")
    static let shapes = CorpusTests.repoRoot.appendingPathComponent("Corpus/features/shapes-lines.key")

    func drawable(_ document: KeynoteDocument, slide: Int, type: UInt32) -> [UInt64] {
        document.slideDrawables(document.slideOrder()[slide].slide).filter { document.store.record(for: $0)?.info.messageInfos.first?.type == type }
    }

    @Test("an image moves and resizes, and the result reopens with that frame", .enabled(if: FileManager.default.fileExists(atPath: images.path), "no Corpus/features"))
    func image() throws {
        var document = try KeynoteDocument.open(Self.images)
        let id = try #require(drawable(document, slide: 0, type: 3005).first)
        let before = try #require(document.movableFrame(id))
        try document.moveDrawable(id, dx: 10, dy: -5)
        #expect(document.movableFrame(id) == KeynoteDocument.Frame(x: before.x + 10, y: before.y - 5, width: before.width, height: before.height))
        try document.setDrawableFrame(id, .init(x: 100, y: 100, width: before.width * 2, height: before.height * 2))
        let reopened = try KeynoteDocument.open(IWAPackageRoundTrip.bytes(document))
        #expect(reopened.movableFrame(id) == KeynoteDocument.Frame(x: 100, y: 100, width: before.width * 2, height: before.height * 2))
        #expect(reopened.validate().filter { $0.severity == .error }.isEmpty)
    }

    @Test("a cropped photo is placed by what shows: its mask's frame", .enabled(if: FileManager.default.fileExists(atPath: template.path), "no Corpus/templates"))
    func croppedImage() throws {
        var document = try KeynoteDocument.open(Self.template)
        let id = try #require(drawable(document, slide: 1, type: 3005).first)
        #expect(document.movableFrame(id) == KeynoteDocument.Frame(x: 0, y: 0, width: 1920, height: 1080))
        try document.setDrawableFrame(id, .init(x: 200, y: 100, width: 960, height: 540))
        #expect(document.movableFrame(id) == KeynoteDocument.Frame(x: 200, y: 100, width: 960, height: 540))
        let image = try #require(document.decoded(TSD_ImageArchive.self, id))
        #expect(abs(Double(image.super.geometry.size.width) - 1053) < 0.01)
    }

    @Test("rotated drawables and bad frames are refused", .enabled(if: FileManager.default.fileExists(atPath: shapes.path), "no Corpus/features"))
    func refusals() throws {
        var document = try KeynoteDocument.open(Self.shapes)
        let rotated = try #require(drawable(document, slide: 0, type: 2011).first { (document.decoded(TSWP_ShapeInfoArchive.self, $0)?.super.super.geometry.angle ?? 0) != 0 })
        #expect(throws: KeynoteDocument.DrawableGeometryFailure.self) { try document.moveDrawable(rotated, dx: 1, dy: 1) }
        let plain = try #require(drawable(document, slide: 1, type: 2011).first)
        #expect(throws: KeynoteDocument.DrawableGeometryFailure.invalidFrame) { try document.setDrawableFrame(plain, .init(x: .nan, y: 0, width: 10, height: 10)) }
        #expect(throws: KeynoteDocument.DrawableGeometryFailure.invalidFrame) { try document.setDrawableFrame(plain, .init(x: 0, y: 0, width: 0, height: 10)) }
    }
}

enum IWAPackageRoundTrip {
    static func bytes(_ document: KeynoteDocument) throws -> IWAPackage { try IWAPackage.openZip(document.serializedData()) }
}

@Suite("Drawable delete")
struct DrawableDeleteTests {
    @Test("an image goes with what only it used, its data included; placeholders are refused", .enabled(if: FileManager.default.fileExists(atPath: DrawableGeometryTests.images.path), "no Corpus/features"))
    func image() throws {
        var document = try KeynoteDocument.open(DrawableGeometryTests.images)
        let slide = document.slideOrder()[0].slide
        let id = try #require(document.slideDrawables(slide).first { document.store.record(for: $0)?.info.messageInfos.first?.type == 3005 })
        let dataBefore = document.packageMetadata?.datas.count ?? 0
        let report = try document.deleteDrawable(id)
        #expect(report.removedObjects >= 1 && document.store.record(for: id) == nil)
        #expect(!document.slideDrawables(slide).contains(id))
        let reopened = try KeynoteDocument.open(IWAPackageRoundTrip.bytes(document))
        #expect(reopened.validate().filter { $0.severity == .error }.isEmpty)
        #expect((reopened.packageMetadata?.datas.count ?? 0) == dataBefore - report.removedData.count)

        var template = try KeynoteDocument.open(DrawableGeometryTests.template)
        let title = try #require(template.slideText(template.slideOrder()[1].slide)?.title)
        let placeholder = try #require(template.location(of: title)?.shape)
        #expect(throws: KeynoteDocument.DrawableDeleteFailure.self) { try template.deleteDrawable(placeholder) }
    }
}
