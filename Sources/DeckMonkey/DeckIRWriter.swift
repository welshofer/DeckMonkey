import Foundation
import KeynoteGraph
import LecternIR

/// Phase 4: a `lectern.deck/1` Deck IR to a `.key`, by surgery on a Keynote-authored template
/// (docs/spec.md §12). Nothing is synthesized: every IR slide starts as a clone of the template's
/// own sample slide for the master its layout maps to, its placeholders' text is set from the IR
/// (`setParagraphs`, so the theme's styles carry the words), and the template's sample slides are
/// deleted at the end. A layout with no master mapping, or a template without the master, is
/// refused rather than approximated.
///
/// Layout → master (Apple theme names): title → Title, sectionHeader → Section, bullets → Title &
/// Bullets, agenda → Agenda (else Title & Bullets), statement → Statement, bigNumber → Big Fact,
/// quote → Quote, closing → Title. Bullets nest one level (sub-bullets at level 1). Content the
/// master has no place for (a title on a Statement, an image brief, a lead) is reported, not drawn.
public enum DeckIRWriter {
    public struct Report: Equatable, Sendable {
        /// Each IR slide's id and the master it was built on.
        public var slides: [(id: String, master: String)] = []
        /// IR content with no place on its master, as "slide id: field".
        public var ignored: [String] = []

        public static func == (a: Report, b: Report) -> Bool {
            a.slides.map(\.id) == b.slides.map(\.id) && a.slides.map(\.master) == b.slides.map(\.master) && a.ignored == b.ignored
        }
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedLayout(slide: String, layout: String)
        case noSampleSlide(slide: String, masters: [String])
        case noPlaceholder(slide: String, role: String)
        case emptyDeck

        public var description: String {
            switch self {
            case .unsupportedLayout(let slide, let layout):
                return "slide \(slide): layout “\(layout)” has no master mapping yet (supported: \(DeckIRWriter.supportedLayouts.joined(separator: ", ")))"
            case .noSampleSlide(let slide, let masters):
                return "slide \(slide): the template has no sample slide on \(masters.map { "“\($0)”" }.joined(separator: " or "))"
            case .noPlaceholder(let slide, let role): return "slide \(slide): its master has no \(role)"
            case .emptyDeck: return "the IR has no slides"
            }
        }
    }

    /// Masters for each supported layout, in preference order.
    static let masters: [String: [String]] = [
        "title": ["Title"], "sectionHeader": ["Section"], "bullets": ["Title & Bullets"],
        "agenda": ["Agenda", "Title & Bullets"], "statement": ["Statement"], "bigNumber": ["Big Fact"],
        "quote": ["Quote"], "closing": ["Title"],
    ]
    public static var supportedLayouts: [String] { masters.keys.sorted() }

    public static func build(_ ir: DeckIR, template: KeynoteDocument) throws -> (KeynoteDocument, Report) {
        guard !ir.slides.isEmpty else { throw Failure.emptyDeck }
        var document = template
        var report = Report()
        let originals = try document.slideList().count
        let sampleMasters = try document.slideMasters()
        for slide in ir.slides {
            guard let candidates = masters[slide.layout] else { throw Failure.unsupportedLayout(slide: slide.id, layout: slide.layout) }
            guard let (index, master) = candidates.lazy.compactMap({ m in sampleMasters.firstIndex(of: m).map { ($0, m) } }).first else {
                throw Failure.noSampleSlide(slide: slide.id, masters: candidates)
            }
            let clone = try document.cloneSlide(at: index, to: try document.slideList().count)
            guard let targets = document.slideText(clone.slide) else { throw Failure.noPlaceholder(slide: slide.id, role: "text") }
            try fill(&document, targets: targets, slide: slide, meta: ir.meta, report: &report)
            report.slides.append((slide.id, master))
        }
        for i in (0..<originals).reversed() { try document.deleteSlide(at: i) }
        return (document, report)
    }

    typealias Paragraph = TextParagraphs.Paragraph

    static func fill(_ d: inout KeynoteDocument, targets: SlideText, slide: IRSlide, meta: Meta, report: inout Report) throws {
        let body = slide.body
        func set(_ storage: UInt64?, _ role: String, _ paragraphs: [Paragraph]) throws {
            guard let storage else { throw Failure.noPlaceholder(slide: slide.id, role: role) }
            try d.setParagraphs(in: storage, paragraphs.isEmpty ? [Paragraph("")] : paragraphs)
        }
        func lines(_ s: String?) -> [Paragraph] { s.map { [Paragraph($0)] } ?? [] }
        func ignore(_ field: String, _ present: Bool) { if present { report.ignored.append("\(slide.id): \(field)") } }

        switch slide.layout {
        case "title":
            try set(targets.title, "title placeholder", lines(slide.title ?? meta.title))
            try set(targets.body, "body placeholder", lines(body?.subtitle ?? (slide.title == nil ? meta.subtitle : nil)))
        case "sectionHeader":
            try set(targets.title, "title placeholder", lines(slide.title))
            if let kicker = body?.kicker { try set(targets.body, "body placeholder", lines(kicker)) }
        case "bullets":
            try set(targets.title, "title placeholder", lines(slide.title))
            var paragraphs = [Paragraph]()
            for bullet in body?.bullets ?? [] {
                paragraphs.append(Paragraph(bullet.text, level: 0))
                paragraphs += (bullet.subBullets ?? []).map { Paragraph($0, level: 1) }
            }
            try set(targets.body, "body placeholder", paragraphs)
            ignore("lead", body?.lead != nil)
        case "agenda":
            try set(targets.title, "title placeholder", lines(slide.title))
            try set(targets.body, "body placeholder", (body?.items ?? []).map { Paragraph($0) })
        case "statement":
            try set(targets.body, "body placeholder", lines(body?.claim ?? slide.title))
            ignore("title", body?.claim != nil && slide.title != nil)
        case "bigNumber":
            try set(targets.body, "body placeholder", lines(body?.value))
            if let label = body?.label {
                guard let box = targets.textBoxes.first else { throw Failure.noPlaceholder(slide: slide.id, role: "label text box") }
                try d.setParagraphs(in: box, [Paragraph(label)])
            }
            ignore("title", slide.title != nil)
        case "quote":
            try set(targets.body, "body placeholder", lines(body?.quote))
            if let attribution = body?.attribution {
                guard let box = targets.textBoxes.first else { throw Failure.noPlaceholder(slide: slide.id, role: "attribution text box") }
                try d.setParagraphs(in: box, [Paragraph(attribution)])
            }
            ignore("title", slide.title != nil)
        case "closing":
            try set(targets.title, "title placeholder", lines(body?.callToAction ?? slide.title))
            try set(targets.body, "body placeholder", lines(body?.contact))
            ignore("title", body?.callToAction != nil && slide.title != nil)
        default:
            throw Failure.unsupportedLayout(slide: slide.id, layout: slide.layout)
        }
        if let notes = slide.notes, let storage = targets.notes {
            try d.setParagraphs(in: storage, notes.components(separatedBy: "\n").map { Paragraph($0) })
        } else if slide.notes != nil {
            report.ignored.append("\(slide.id): notes")
        }
        ignore("image", slide.image != nil)
        ignore("source", body?.source != nil)
    }
}
