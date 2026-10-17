import Foundation
import Testing
@testable import DeckMonkey

/// Inserting text boxes and pictures from the bundled parts into every template: the result
/// validates, reopens, and holds the new object in the target theme's own styles.
@Suite("Parts")
struct PartsTests {
    static let templates: [URL] = ((try? FileManager.default.contentsOfDirectory(at: DeckIRWriterTests.root.appendingPathComponent("Corpus/templates"), includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "key" }.sorted { $0.path < $1.path }
    static let png: Data = {
        // A 2 × 2 RGB PNG.
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP8z8DAwMDAxMDAwMDAAAANHQEDasKb6QAAAABJRU5ErkJggg==")!
    }()

    @Test("the parts packages are small and hold one part each")
    func packages() throws {
        let text = try Parts.document(.textBox), picture = try Parts.document(.picture)
        #expect(text.parts.textBox != nil && picture.parts.image != nil)
        #expect(text.store.identifiers.count < 20 && picture.store.identifiers.count < 20)
    }

    @Test("a text box and a picture insert into every template", .enabled(if: !templates.isEmpty, "no Corpus/templates"))
    func everyTemplate() throws {
        var failures = [String]()
        for template in Self.templates {
            do {
                var document = try KeynoteDocument.open(template)
                let slide = try document.slideList()[0].slide
                let box = try document.insertTextBox(onto: slide, frame: .init(x: 100, y: 100, width: 600, height: 0), text: "Inserted\nby Duo")
                let picture = try document.insertImage(Self.png, preferredFileName: "pixel.png", onto: slide, frame: .init(x: 800, y: 300, width: 200, height: 200))
                let reopened = try KeynoteDocument.open(IWAPackage.openZip(document.serializedData()))
                #expect(reopened.validate().filter { $0.severity == .error }.isEmpty, "\(template.lastPathComponent)")
                #expect(reopened.slideDrawables(slide).suffix(2) == [box, picture])
                let storage = try #require(reopened.decoded(TSWP_ShapeInfoArchive.self, box)?.ownedStorage.identifier)
                #expect(reopened.storageText(storage) == "Inserted\nby Duo")
            } catch {
                failures.append("\(template.lastPathComponent): \(error)")
            }
        }
        for f in failures { print("FAIL", f) }
        #expect(failures.isEmpty)
        print("parts: \(Self.templates.count - failures.count)/\(Self.templates.count) templates")
    }
}
