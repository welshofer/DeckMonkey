import Foundation
import KeynoteGraph
import LecternIR
import Rostrum
import RostrumLayout

/// Phase 4: a `lectern.deck/1` Deck IR to a `.key`, by surgery on a Keynote-authored template
/// (docs/spec.md §12). Nothing is synthesized.
///
/// The IR is first turned into a `DeckPlan`: for every slide the master it is built on, the text
/// of its placeholders and of the master's free text box, its notes, and the new drawables it needs
/// (theme-default shapes and text boxes, with frames in points). The plan is then applied: each
/// slide clones the template's own sample slide for its master, the text is set (`setParagraphs`),
/// each new drawable is a copy of a Keynote-authored plain shape or text item from a parts deck
/// (`Corpus/features/drawables.key`), restyled to the theme's defaults by identifier
/// (`insertDrawable`), and the template's sample slides are deleted. Gate 4 has Keynote build the
/// same plan through AppleScript, so the golden is Keynote's own rendering of identical content.
///
/// Layouts: title → Title, sectionHeader → Section, bullets / imageLeft / imageRight → Title &
/// Bullets, agenda → Agenda (else Title & Bullets), statement → Statement, bigNumber → Big Fact,
/// quote → Quote, closing → Title; metrics, bands, diagram (process, cycle, pyramid), timeline and
/// quadrant → Title Only with one theme-default shape per item in Rostrum's StructuredLayout
/// cells over the theme's body area (and an arrow between ordered steps); twoColumn and
/// comparison → Title Only with two text boxes; callout → Title Only with a band shape and a text
/// box; chart → Title Only with a copy of a Keynote-made chart of that type (charts.key) over the
/// body area, its data replaced. Styles stay the theme's (invariant 6: no overrides are created).
/// table → a Title Only slide holding a Keynote-made table of that size from tables-parts.key,
/// imported (restyled to the theme's table preset in the same slot) and its strings replaced.
/// Content with no place is reported.
public enum DeckIRWriter {
    // MARK: Plan

    public struct Paragraph: Codable, Equatable, Sendable {
        public var text: String
        public var level: Int
        public init(_ text: String, level: Int = 0) { self.text = text; self.level = level }
    }

    public struct DrawablePlan: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case shape, textBox, chart }
        public var kind: Kind
        /// Points. A text box has height 0: its width is fixed and its height automatic.
        public var x, y, width, height: Double
        public var paragraphs: [Paragraph]
        /// A chart's data: Keynote's chart type (TSCH.ChartType) and its AppleScript name, the series
        /// (grid rows) and categories (grid columns), values[series][category].
        public var chart: ChartPlan?

        /// Frames are kept in whole points, as Keynote's own UI and AppleScript store them (Rostrum's
        /// geometry is in EMU, whose conversion leaves fractions of a point).
        public init(kind: Kind, x: Double, y: Double, width: Double, height: Double, paragraphs: [Paragraph], chart: ChartPlan? = nil) {
            self.kind = kind; self.x = x.rounded(); self.y = y.rounded(); self.width = width.rounded(); self.height = height.rounded()
            self.paragraphs = paragraphs; self.chart = chart
        }
    }

    public struct ChartPlan: Codable, Equatable, Sendable {
        public var chartType: Int
        public var appleScriptType: String
        public var rows: [String]
        public var columns: [String]
        public var values: [[Double]]
    }

    /// IR chart kind → Keynote chart type and AppleScript's name for it (the kinds the parts deck,
    /// Corpus/features/charts.key, holds).
    static let chartKinds: [String: (type: Int, appleScript: String)] = [
        "bar": (1, "vertical_bar_2d"), "column": (1, "vertical_bar_2d"), "line": (3, "line_2d"), "area": (4, "area_2d"),
        "pie": (5, "pie_2d"), "stackedbar": (6, "stacked_vertical_bar_2d"),
    ]

    public struct SlidePlan: Codable, Equatable, Sendable {
        public var id: String
        public var master: String
        public var title: [Paragraph]?
        public var body: [Paragraph]?
        /// The master's free text box (Big Fact's label, Quote's attribution).
        public var box: [Paragraph]?
        public var notes: [Paragraph]?
        public var drawables: [DrawablePlan] = []
        /// A table's cells, header row first, every row padded to the widest: the slide is a
        /// parts-deck table slide of that size (tables-parts.key), its strings replaced.
        public var table: [[String]]?
    }

    public struct DeckPlan: Codable, Equatable, Sendable {
        public var slides: [SlidePlan]
        /// IR content with no place on its slide, as "slide id: field".
        public var ignored: [String]
    }

    public struct Report: Equatable, Sendable {
        public var slides: [(id: String, master: String)] = []
        public var ignored: [String] = []

        public static func == (a: Report, b: Report) -> Bool {
            a.slides.map(\.id) == b.slides.map(\.id) && a.slides.map(\.master) == b.slides.map(\.master) && a.ignored == b.ignored
        }
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedLayout(slide: String, layout: String)
        case noSampleSlide(slide: String, masters: [String])
        case noPlaceholder(slide: String, role: String)
        case noParts(slide: String)
        case noContentRegion
        case layout(slide: String, String)
        case emptyDeck

        public var description: String {
            switch self {
            case .unsupportedLayout(let slide, let layout):
                return "slide \(slide): layout “\(layout)” has no mapping yet (supported: \(DeckIRWriter.supportedLayouts.joined(separator: ", ")))"
            case .noSampleSlide(let slide, let masters):
                return "slide \(slide): the template has no sample slide on \(masters.map { "“\($0)”" }.joined(separator: " or "))"
            case .noPlaceholder(let slide, let role): return "slide \(slide): its master has no \(role)"
            case .noParts(let slide): return "slide \(slide) needs a new shape, text box or chart the parts decks do not hold (Corpus/features/drawables.key and charts.key, `make corpus`)"
            case .noContentRegion: return "the template has no Title & Bullets sample slide to take the content area from"
            case .layout(let slide, let detail): return "slide \(slide): \(detail)"
            case .emptyDeck: return "the IR has no slides"
            }
        }
    }

    static let masters: [String: [String]] = [
        "title": ["Title"], "sectionHeader": ["Section"], "bullets": ["Title & Bullets"], "imageLeft": ["Title & Bullets"],
        "imageRight": ["Title & Bullets"], "agenda": ["Agenda", "Title & Bullets"], "statement": ["Statement"],
        "bigNumber": ["Big Fact"], "quote": ["Quote"], "closing": ["Title"],
        "metrics": ["Title Only"], "bands": ["Title Only"], "diagram": ["Title Only"], "timeline": ["Title Only"],
        "quadrant": ["Title Only"], "twoColumn": ["Title Only"], "comparison": ["Title Only"], "callout": ["Title Only"],
        "chart": ["Title Only"], "table": ["Title Only"],
    ]
    public static var supportedLayouts: [String] { masters.keys.sorted() }

    /// The plan for `ir` on `template`.
    public static func plan(_ ir: DeckIR, template: KeynoteDocument) throws -> DeckPlan {
        guard !ir.slides.isEmpty else { throw Failure.emptyDeck }
        let list = try template.slideList()
        let sampleMasters = try template.slideMasters()
        // The content area: the theme's own body placeholder on its Title & Bullets sample.
        let region: KeynoteDocument.Frame? = sampleMasters.firstIndex(of: "Title & Bullets").flatMap { template.slideText(list[$0].slide)?.bodyFrame }
        var plan = DeckPlan(slides: [], ignored: [])
        for slide in ir.slides {
            guard let candidates = masters[slide.layout] else { throw Failure.unsupportedLayout(slide: slide.id, layout: slide.layout) }
            guard let master = candidates.first(where: { sampleMasters.contains($0) }) else {
                throw Failure.noSampleSlide(slide: slide.id, masters: candidates)
            }
            var s = SlidePlan(id: slide.id, master: master)
            try fill(&s, slide: slide, meta: ir.meta, region: region, ignored: &plan.ignored)
            if let notes = slide.notes { s.notes = notes.components(separatedBy: "\n").map { Paragraph($0) } }
            plan.slides.append(s)
        }
        return plan
    }

    static func fill(_ s: inout SlidePlan, slide: IRSlide, meta: Meta, region: KeynoteDocument.Frame?, ignored: inout [String]) throws {
        let body = slide.body
        func lines(_ t: String?) -> [Paragraph]? { t.map { [Paragraph($0)] } }
        func ignore(_ field: String, _ present: Bool) { if present { ignored.append("\(slide.id): \(field)") } }
        func bullets(_ list: [Bullet]?) -> [Paragraph] {
            (list ?? []).flatMap { [Paragraph($0.text)] + ($0.subBullets ?? []).map { Paragraph($0, level: 1) } }
        }
        func area() throws -> KeynoteDocument.Frame {
            guard let region else { throw Failure.noContentRegion }
            return region
        }
        switch slide.layout {
        case "title":
            s.title = lines(slide.title ?? meta.title)
            s.body = lines(body?.subtitle ?? (slide.title == nil ? meta.subtitle : nil))
        case "sectionHeader":
            s.title = lines(slide.title)
            s.body = lines(body?.kicker)
        case "bullets", "imageLeft", "imageRight":
            s.title = lines(slide.title)
            s.body = bullets(body?.bullets)
            ignore("lead", body?.lead != nil)
            ignore("kicker", body?.kicker != nil)
        case "agenda":
            s.title = lines(slide.title)
            s.body = (body?.items ?? []).map { Paragraph($0) }
        case "statement":
            s.body = lines(body?.claim ?? slide.title)
            ignore("title", body?.claim != nil && slide.title != nil)
        case "bigNumber":
            s.body = lines(body?.value)
            s.box = lines(body?.label)
            ignore("title", slide.title != nil)
        case "quote":
            s.body = lines(body?.quote)
            s.box = lines(body?.attribution)
            ignore("title", slide.title != nil)
        case "closing":
            s.title = lines(body?.callToAction ?? slide.title)
            s.body = lines(body?.contact)
            ignore("title", body?.callToAction != nil && slide.title != nil)
        case "metrics":
            s.title = lines(slide.title)
            let items = (body?.stats ?? []).map { ($0.value, $0.label) }
            s.drawables = try structured(.metrics, items, in: try area(), slide: slide.id)
        case "bands":
            s.title = lines(slide.title)
            let declared = body?.items ?? []
            let items = (declared.isEmpty ? bullets(body?.bullets).map(\.text) : declared).map { ($0, "") }
            s.drawables = try structured(.bands, items, in: try area(), slide: slide.id)
        case "diagram":
            s.title = lines(slide.title)
            let kind: StructuredKind
            switch body?.diagram?.kind.lowercased() {
            case "pyramid": kind = .pyramid
            case "cycle": kind = .cycle
            default: kind = .process
            }
            let items = (body?.diagram?.items ?? []).map { item -> (String, String) in
                let parts = item.components(separatedBy: " — ")
                return parts.count > 1 ? (parts[0], parts.dropFirst().joined(separator: " — ")) : (item, "")
            }
            s.drawables = try structured(kind, items, in: try area(), slide: slide.id)
        case "timeline":
            s.title = lines(slide.title)
            s.drawables = try structured(.timeline, (body?.milestones ?? []).map { ($0.label, $0.detail) }, in: try area(), slide: slide.id)
        case "quadrant":
            s.title = lines(slide.title)
            s.drawables = try structured(.quadrant, (body?.quadrants ?? []).map { ($0.heading, $0.detail) }, in: try area(), slide: slide.id)
            ignore("xAxis", body?.xAxis != nil)
            ignore("yAxis", body?.yAxis != nil)
        case "twoColumn", "comparison":
            s.title = lines(slide.title)
            let r = try area(), gap = 16.0, w = (r.width - gap) / 2
            for (i, column) in [body?.left, body?.right].enumerated() {
                guard let column else { continue }
                let paragraphs = (column.heading.isEmpty ? [] : [Paragraph(column.heading)]) + column.bullets.map { Paragraph($0) }
                s.drawables.append(.init(kind: .textBox, x: r.x + Double(i) * (w + gap), y: r.y, width: w, height: 0, paragraphs: paragraphs))
            }
            ignore("lead", body?.lead != nil)
        case "callout":
            s.title = lines(slide.title)
            let r = try area(), band = r.height * 0.25
            if let text = body?.band, !text.isEmpty {
                s.drawables.append(.init(kind: .shape, x: r.x, y: r.y, width: r.width, height: band, paragraphs: [Paragraph(text)]))
            }
            let rest = bullets(body?.bullets)
            if !rest.isEmpty {
                s.drawables.append(.init(kind: .textBox, x: r.x, y: r.y + band + 24, width: r.width, height: 0, paragraphs: rest))
            }
            ignore("lead", body?.lead != nil)
            ignore("kicker", body?.kicker != nil)
        case "table":
            s.title = lines(slide.title)
            guard let t = body?.table, !t.headers.isEmpty else { throw Failure.layout(slide: slide.id, "the table needs a header row") }
            let width = max(t.headers.count, t.rows.map(\.count).max() ?? 0)
            s.table = t.grid.map { $0 + Array(repeating: "", count: width - $0.count) }
        case "chart":
            s.title = lines(slide.title)
            guard let c = body?.chart, !c.categories.isEmpty, !c.series.isEmpty,
                  c.series.allSatisfy({ $0.values.count == c.categories.count }) else {
                throw Failure.layout(slide: slide.id, "the chart needs categories and one value per category in every series")
            }
            guard let kind = chartKinds[c.kind.lowercased()] else {
                throw Failure.layout(slide: slide.id, "chart kind “\(c.kind)” has no Keynote counterpart yet (\(chartKinds.keys.sorted().joined(separator: ", ")))")
            }
            let r = try area()
            s.drawables.append(.init(kind: .chart, x: r.x, y: r.y, width: r.width, height: r.height, paragraphs: [],
                                     chart: ChartPlan(chartType: kind.type, appleScriptType: kind.appleScript, rows: c.series.map(\.name),
                                                      columns: c.categories, values: c.series.map(\.values))))
        default:
            throw Failure.unsupportedLayout(slide: slide.id, layout: slide.layout)
        }
        ignore("image", slide.image != nil)
        ignore("source", body?.source != nil)
    }

    /// Rostrum's StructuredLayout cells over `region`: one theme-default shape per item (heading,
    /// then detail, as paragraphs), and for ordered kinds an arrow text box between steps, placed
    /// as Rostrum places it.
    static func structured(_ kind: StructuredKind, _ items: [(String, String)], in region: KeynoteDocument.Frame, slide: String) throws -> [DrawablePlan] {
        guard !items.isEmpty else { throw Failure.layout(slide: slide, "no items") }
        let rect = Rect(x: .points(region.x), y: .points(region.y), width: .points(region.width), height: .points(region.height))
        let cells: [Rect]
        do { cells = try StructuredLayout.frames(kind: kind, count: items.count, in: rect) } catch { throw Failure.layout(slide: slide, "\(error)") }
        var out = [DrawablePlan]()
        for ((heading, detail), cell) in zip(items, cells) {
            let paragraphs = [Paragraph(heading)] + (detail.isEmpty ? [] : [Paragraph(detail)])
            out.append(.init(kind: .shape, x: cell.x.points, y: cell.y.points, width: cell.width.points, height: cell.height.points, paragraphs: paragraphs))
        }
        if [.process, .timeline, .cycle].contains(kind) {
            for (i, cell) in cells.enumerated() where i + 1 < cells.count {
                let next = cells[i + 1]
                let sameRow = next.y == cell.y
                let arrow = sameRow ? (next.x > cell.x ? "→" : "←") : (next.y > cell.y ? "↓" : "↑")
                let x = sameRow ? min(cell.maxX.points, next.maxX.points) : cell.x.points + cell.width.points / 2 - 8
                let y = sameRow ? cell.y.points + cell.height.points / 2 - 12 : min(cell.maxY.points, next.maxY.points)
                out.append(.init(kind: .textBox, x: x, y: y, width: 16, height: 0, paragraphs: [Paragraph(arrow)]))
            }
        }
        return out
    }

    // MARK: Apply

    /// Builds `plan` on `template`, copying new drawables from `parts` (needed only when a slide
    /// has some).
    public static func apply(_ plan: DeckPlan, template: KeynoteDocument, parts: [KeynoteDocument]) throws -> (KeynoteDocument, Report) {
        var document = template
        var report = Report(slides: [], ignored: plan.ignored)
        let originals = try document.slideList().count
        let sampleMasters = try document.slideMasters()
        // The parts: the drawables deck's plain text item (slide 1) and shape (slide 2), and the
        // first chart of each type any parts deck holds.
        var textItem: (KeynoteDocument, UInt64)?, shape: (KeynoteDocument, UInt64)?
        var charts = [Int: (KeynoteDocument, UInt64)]()
        for deck in parts {
            guard let list = try? deck.slideList() else { continue }
            if textItem == nil, list.count >= 2, deck.chartType(of: deck.slideDrawables(list[0].slide).first ?? 0) == nil,
               let t = deck.slideDrawables(list[0].slide).first, let sh = deck.slideDrawables(list[1].slide).first,
               deck.chartType(of: sh) == nil {
                textItem = (deck, t); shape = (deck, sh)
            }
            for entry in list {
                for id in deck.slideDrawables(entry.slide) {
                    if let type = deck.chartType(of: id), charts[type] == nil { charts[type] = (deck, id) }
                }
            }
        }
        // Table parts: the parts deck slide holding a table of each size.
        var tableSlides = [String: (KeynoteDocument, Int)]()
        for deck in parts {
            guard let list = try? deck.slideList() else { continue }
            for (i, entry) in list.enumerated() {
                for model in deck.slideTables(entry.slide) {
                    if let size = deck.tableSize(model), tableSlides["\(size.rows)x\(size.columns)"] == nil { tableSlides["\(size.rows)x\(size.columns)"] = (deck, i) }
                }
            }
        }
        for s in plan.slides {
            let newSlide: UInt64
            if let cells = s.table {
                let key = "\(cells.count)x\(cells.first?.count ?? 0)"
                guard let (deck, index) = tableSlides[key] else { throw Failure.layout(slide: s.id, "no parts table of size \(key) (tables-parts.key holds 2-10 rows by 2-6 columns)") }
                newSlide = try document.importSlide(at: index, from: deck).slide
                if let sample = sampleMasters.firstIndex(of: s.master) {
                    try document.alignPlaceholders(of: newSlide, like: try document.slideList()[sample].slide)
                }
                guard let model = document.slideTables(newSlide).first else { throw Failure.layout(slide: s.id, "the parts slide lost its table") }
                try document.setTableCells(model, cells)
            } else {
                guard let index = sampleMasters.firstIndex(of: s.master) else { throw Failure.noSampleSlide(slide: s.id, masters: [s.master]) }
                newSlide = try document.cloneSlide(at: index, to: try document.slideList().count).slide
            }
            guard let targets = document.slideText(newSlide) else { throw Failure.noPlaceholder(slide: s.id, role: "text") }
            func set(_ storage: UInt64?, _ role: String, _ paragraphs: [Paragraph]?) throws {
                guard let paragraphs else { return }
                guard let storage else { throw Failure.noPlaceholder(slide: s.id, role: role) }
                let p = paragraphs.isEmpty ? [TextParagraphs.Paragraph("")] : paragraphs.map { TextParagraphs.Paragraph($0.text, level: $0.level) }
                try document.setParagraphs(in: storage, p)
            }
            // A placeholder the plan leaves alone is emptied, as on a slide Keynote makes from the
            // master; the sample slide's own words never survive.
            try set(targets.title, "title placeholder", s.title ?? (targets.title == nil ? nil : []))
            try set(targets.body, "body placeholder", s.body ?? (targets.body == nil ? nil : []))
            try set(targets.textBoxes.first, "free text box", s.box)
            if s.notes != nil {
                if targets.notes == nil { report.ignored.append("\(s.id): notes") } else { try set(targets.notes, "notes", s.notes) }
            }
            for d in s.drawables {
                let source: (KeynoteDocument, UInt64)?
                switch d.kind {
                case .shape: source = shape
                case .textBox: source = textItem
                case .chart: source = d.chart.flatMap { charts[$0.chartType] }
                }
                guard let (deck, part) = source else { throw Failure.noParts(slide: s.id) }
                let new = try document.insertDrawable(part, from: deck, onto: newSlide,
                                                      frame: .init(x: d.x, y: d.y, width: d.width, height: d.height),
                                                      paragraphs: d.kind == .chart ? nil : d.paragraphs.map { TextParagraphs.Paragraph($0.text, level: $0.level) })
                if let c = d.chart { try document.setChartData(new, rows: c.rows, columns: c.columns, values: c.values) }
            }
            report.slides.append((s.id, s.master))
        }
        for i in (0..<originals).reversed() { try document.deleteSlide(at: i) }
        return (document, report)
    }

    /// Plan and apply.
    public static func build(_ ir: DeckIR, template: KeynoteDocument, parts: [KeynoteDocument] = []) throws -> (KeynoteDocument, Report) {
        try apply(try plan(ir, template: template), template: template, parts: parts)
    }
}
