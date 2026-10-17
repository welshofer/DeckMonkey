import Foundation
import IWAArchive
import IWASchema
import SwiftProtobuf

/// Phase 4: put a new drawable on a slide by copying a Keynote-authored one (docs/spec.md §12).
///
/// Nothing is synthesized: the source is a drawable Keynote made (`Corpus/features/drawables.key`
/// holds a plain text item, shape and line, made through AppleScript with no overrides, so their
/// styles are the theme's defaults). The drawable and what only it keeps alive (its text storage,
/// title and caption) are copied onto the slide with fresh identifiers and UUIDs; every reference
/// leaving the copy is re-pointed at this deck as `importSlide` does (styles by identifier, so the
/// copy takes this theme's default text box, shape or line style; the parent to the slide); the
/// geometry is set and, for a shape with text, the text. The copy is the last drawable in z order.
extension KeynoteDocument {
    public enum DrawableInsertFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case notADrawable(UInt64)
        case noSlide(UInt64)
        case unmatchedStyles([String])

        public var description: String {
            switch self {
            case .notADrawable(let id): return "object \(id) of the source is not a shape (TSWP.ShapeInfoArchive)"
            case .noSlide(let id): return "\(id) is not a slide of this deck"
            case .unmatchedStyles(let styles): return "this deck has no match for \(styles.joined(separator: ", ")); no styles are created (invariant 6)"
            }
        }
    }

    /// Copies shape `drawable` of `source` onto `slide`, at `frame` (points): width and height
    /// fix the size; a width alone fixes the width and leaves the height automatic (a text box);
    /// neither keeps the source's. `paragraphs` become its text when given. Returns the new
    /// drawable's identifier.
    @discardableResult
    public mutating func insertDrawable(_ drawable: UInt64, from source: KeynoteDocument, onto slide: UInt64, frame: Frame,
                                        paragraphs: [TextParagraphs.Paragraph]? = nil) throws -> UInt64 {
        let sourceType = source.store.record(for: drawable)?.info.messageInfos.first?.type
        guard sourceType == Self.shapeInfoType || sourceType == Self.chartDrawableType || sourceType == Self.imageType else {
            throw DrawableInsertFailure.notADrawable(drawable)
        }
        guard var slideArchive = decoded(KN_SlideArchive.self, slide), let component = store.entry(for: slide)?.component,
              let metadata = packageMetadata else { throw DrawableInsertFailure.noSlide(slide) }
        let sourceSlide = sourceType == Self.chartDrawableType
            ? source.decoded(TSCH_ChartDrawableArchive.self, drawable)?.super.parent.identifier ?? 0
            : sourceType == Self.imageType
            ? source.decoded(TSD_ImageArchive.self, drawable)?.super.parent.identifier ?? 0
            : source.decoded(TSWP_ShapeInfoArchive.self, drawable)?.super.super.parent.identifier ?? 0
        var keep: Set<UInt64> = [sourceSlide]
        if let show = source.showIdentifier { keep.insert(show) }
        let copied = source.heldOnly(by: [drawable], referrers: source.referrerIndex(), keeping: keep)

        var allocator = IDAllocator(seed: max(store.highestIdentifier, metadata.lastObjectIdentifier) + 1)
        var identifiers = [UInt64: UInt64]()
        for id in copied.sorted() { identifiers[id] = allocator.allocate() }
        if sourceSlide != 0 { identifiers[sourceSlide] = slide }

        var resolver = try ForeignResolver(target: self)
        resolver.learnVariations(from: source)
        resolver.learnPresets(from: source)
        var unmatched = [String]()
        for id in copied.sorted() {
            guard let record = source.store.record(for: id) else { continue }
            for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil && i < record.payloads.count {
                guard let derived = try? ReferenceDerivation.derive(type: info.type, payload: record.payloads[i]) else { continue }
                for ref in derived.objects where identifiers[ref] == nil && ref != 0 {
                    guard source.store.entry(for: ref) != nil else { identifiers[ref] = allocator.allocate(); continue }
                    switch try resolver.resolve(ref, in: source) {
                    case .found(let target): identifiers[ref] = target
                    case .unmatched(let what): if !unmatched.contains(what) { unmatched.append(what) }
                    }
                }
            }
        }
        if !unmatched.isEmpty { throw DrawableInsertFailure.unmatchedStyles(unmatched) }

        // Fresh UUIDs for copied objects the source's UUID maps name.
        var generator = SystemRandomNumberGenerator()
        var uuids = [ReferenceRewriter.UUIDValue: ReferenceRewriter.UUIDValue]()
        var entries = [TSP_ObjectUUIDMapEntry]()
        for c in source.packageMetadata?.components ?? [] {
            for e in c.objectUuidMapEntries where copied.contains(e.identifier) {
                let fresh = ReferenceRewriter.UUIDValue(lower: generator.next(), upper: generator.next())
                uuids[.init(lower: e.uuid.lower, upper: e.uuid.upper)] = fresh
                entries.append(.with { $0.identifier = identifiers[e.identifier]!; $0.uuid = .with { $0.lower = fresh.lower; $0.upper = fresh.upper } })
            }
        }
        let rewriter = ReferenceRewriter(index: try FieldIndex.load(version: TypeRegistry.pinnedVersion), identifiers: identifiers, uuids: uuids)
        for id in copied.sorted() {
            guard let record = source.store.record(for: id) else { continue }
            var info = record.info
            info.setIdentifier(identifiers[id]!)
            var payloads = record.payloads
            for (i, m) in info.messageInfos.enumerated() where i < payloads.count {
                if m.baseMessageIndex == nil, let type = Schema.messageType(for: m.type) {
                    payloads[i] = try rewriter.rewrite(payloads[i], message: type.protoMessageName)
                }
                info.messageInfos[i] = try Self.remapped(m, identifiers: identifiers, length: UInt32(payloads[i].count))
            }
            store.append(ArchiveRecord(info: info, payloads: payloads, isDirty: true), to: component)
        }

        // Geometry as Keynote stores it for what AppleScript makes: a text box with a width keeps
        // its height automatic (size w × 0, flags 1, natural width w); a shape with a size has it
        // fixed (flags 3), its natural size and path scaled to match.
        let new = identifiers[drawable]!
        if sourceType == Self.chartDrawableType {
            // A chart: its geometry is fixed at the frame (flags 3, as AppleScript stores it).
            guard var chart = decoded(TSCH_ChartDrawableArchive.self, new) else { throw DrawableInsertFailure.notADrawable(drawable) }
            // The style lists come from this theme's preset the chart maps to, as `add chart`
            // applies a preset: a source theme's preset may list fewer paragraph styles, and a
            // label whose slot is missing falls back to a default.
            var unity = chart.TSCH_ChartArchive_unity
            if unity.hasPreset, let preset = decoded(TSCH_ChartStylePreset.self, unity.preset.identifier) {
                unity.chartStyle = preset.chartStyle
                unity.legendStyle = preset.legendStyle
                unity.valueAxisStyles = preset.valueAxisStyles
                unity.categoryAxisStyles = preset.categoryAxisStyles
                unity.seriesThemeStyles = preset.seriesStyles
                unity.paragraphStyles = preset.paragraphStyles
                chart.TSCH_ChartArchive_unity = unity
            }
            chart.super.geometry.position = .with { $0.x = Float(frame.x); $0.y = Float(frame.y) }
            if frame.width > 0, frame.height > 0 {
                chart.super.geometry.size = .with { $0.width = Float(frame.width); $0.height = Float(frame.height) }
                chart.super.geometry.flags = 3
            }
            try replacePayload(of: new, with: try chart.serializedData(partial: true))
            try finishInsert(new, onto: slide, slideArchive: &slideArchive, component: component, entries: entries, allocator: allocator)
            return new
        }
        if sourceType == Self.imageType {
            // A picture: fixed at the frame (flags 3), as `make new image` and a resize store it.
            guard var image = decoded(TSD_ImageArchive.self, new) else { throw DrawableInsertFailure.notADrawable(drawable) }
            image.super.geometry.position = .with { $0.x = Float(frame.x); $0.y = Float(frame.y) }
            if frame.width > 0, frame.height > 0 {
                image.super.geometry.size = .with { $0.width = Float(frame.width); $0.height = Float(frame.height) }
                image.super.geometry.flags = 3
                image.originalSize = .with { $0.width = Float(frame.width); $0.height = Float(frame.height) }
            }
            try replacePayload(of: new, with: try image.serializedData(partial: true))
            try finishInsert(new, onto: slide, slideArchive: &slideArchive, component: component, entries: entries, allocator: allocator)
            return new
        }
        guard var shape = decoded(TSWP_ShapeInfoArchive.self, new) else { throw DrawableInsertFailure.notADrawable(drawable) }
        var geometry = shape.super.super.geometry
        geometry.position = .with { $0.x = Float(frame.x); $0.y = Float(frame.y) }
        if frame.width > 0, frame.height > 0 {
            geometry.size = .with { $0.width = Float(frame.width); $0.height = Float(frame.height) }
            geometry.flags = 3
            if shape.super.hasPathsource, shape.super.pathsource.hasBezierPathSource {
                var source = shape.super.pathsource.bezierPathSource
                let old = source.naturalSize
                let sx = old.width > 0 ? Float(frame.width) / old.width : 1, sy = old.height > 0 ? Float(frame.height) / old.height : 1
                for e in source.path.elements.indices {
                    for p in source.path.elements[e].points.indices {
                        source.path.elements[e].points[p].x *= sx
                        source.path.elements[e].points[p].y *= sy
                    }
                }
                source.naturalSize = .with { $0.width = Float(frame.width); $0.height = Float(frame.height) }
                shape.super.pathsource.bezierPathSource = source
            }
        } else if frame.width > 0 {
            geometry.size = .with { $0.width = Float(frame.width); $0.height = 0 }
            geometry.flags = 1
            if shape.super.hasPathsource, shape.super.pathsource.hasBezierPathSource {
                shape.super.pathsource.bezierPathSource.naturalSize.width = Float(frame.width)
            }
        }
        shape.super.super.geometry = geometry
        try replacePayload(of: new, with: try shape.serializedData(partial: true))
        if let paragraphs, shape.hasOwnedStorage {
            try setParagraphs(in: shape.ownedStorage.identifier, paragraphs)
        }

        try finishInsert(new, onto: slide, slideArchive: &slideArchive, component: component, entries: entries, allocator: allocator)
        return new
    }

    /// The new drawable joins the slide's drawables, last in z order; its UUID-map entries and the
    /// identifier high-water mark go into the package metadata.
    mutating func finishInsert(_ new: UInt64, onto slide: UInt64, slideArchive: inout KN_SlideArchive, component: String,
                               entries: [TSP_ObjectUUIDMapEntry], allocator: IDAllocator) throws {
        slideArchive.ownedDrawables.append(TSP_Reference.with { $0.identifier = new })
        slideArchive.drawablesZOrder.append(TSP_Reference.with { $0.identifier = new })
        try replacePayload(of: slide, with: try slideArchive.serializedData(partial: true))
        guard var metadata = packageMetadata else { return }
        let locator = String(component.dropFirst("Index/".count).dropLast(".iwa".count))
        if let c = metadata.components.firstIndex(where: { ($0.locator.isEmpty ? $0.preferredLocator : $0.locator) == locator }) {
            metadata.components[c].objectUuidMapEntries += entries
        }
        metadata.lastObjectIdentifier = max(metadata.lastObjectIdentifier, allocator.highWaterMark)
        try replacePayload(of: 2, with: try metadata.serializedData(partial: true))
    }

    static let chartDrawableType: UInt32 = 5021

    /// The chart type of chart drawable `drawable`, nil when it is not a chart.
    public func chartType(of drawable: UInt64) -> Int? {
        guard store.record(for: drawable)?.info.messageInfos.first?.type == Self.chartDrawableType,
              let chart = decoded(TSCH_ChartDrawableArchive.self, drawable) else { return nil }
        return chart.TSCH_ChartArchive_unity.chartType.rawValue
    }

    /// Chart `drawable`'s data: series names (grid rows), categories (columns), values[row][column].
    public func chartGrid(_ drawable: UInt64) -> (rows: [String], columns: [String], values: [[Double]])? {
        guard store.record(for: drawable)?.info.messageInfos.first?.type == Self.chartDrawableType,
              let chart = decoded(TSCH_ChartDrawableArchive.self, drawable) else { return nil }
        let g = chart.TSCH_ChartArchive_unity.grid
        return (g.rowName, g.columnName, g.gridRow.map { $0.value.map(\.numericValue) })
    }

    /// Replaces chart `drawable`'s data: series are the grid's rows (`rows` their names), categories
    /// its columns, `values[row][column]`; each row and column gets a fresh unique id, as Keynote
    /// gives the rows and columns `add chart` makes.
    public mutating func setChartData(_ drawable: UInt64, rows: [String], columns: [String], values: [[Double]]) throws {
        guard var chart = decoded(TSCH_ChartDrawableArchive.self, drawable) else { throw DrawableInsertFailure.notADrawable(drawable) }
        var unity = chart.TSCH_ChartArchive_unity
        var grid = unity.grid
        grid.rowName = rows
        grid.columnName = columns
        grid.gridRow = values.map { row in TSCH_GridRow.with { $0.value = row.map { v in TSCH_GridValue.with { $0.numericValue = v } } } }
        var ids = TSCH_ChartGridArchive.ChartGridRowColumnIdMap()
        ids.rowIDMap = rows.indices.map { i in .with { $0.uniqueID = Foundation.UUID().uuidString; $0.index = UInt32(i) } }
        ids.columnIDMap = columns.indices.map { i in .with { $0.uniqueID = Foundation.UUID().uuidString; $0.index = UInt32(i) } }
        grid.idMap = ids
        unity.grid = grid
        chart.TSCH_ChartArchive_unity = unity
        try replacePayload(of: drawable, with: try chart.serializedData(partial: true))
    }
}
