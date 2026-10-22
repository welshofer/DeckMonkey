import Foundation
import IWAArchive
import IWASchema
import SwiftProtobuf

/// Style variations: the one kind of style DeckMonkey creates (invariant 6, relaxed by Jay on
/// 2026-10-21 for scene building). A variation is what Keynote writes when a shape or text gets
/// its own fill, stroke or font: a style whose parent is a theme style, flagged `is_variation`,
/// holding only what it overrides. It lives in the document's stylesheet component, is listed in
/// the stylesheet's `styles`, and under its parent in `parent_to_children_style_map`.
extension KeynoteDocument {
    public enum StyleVariationFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case noStylesheet
        case notAStyle(UInt64)

        public var description: String {
            switch self {
            case .noStylesheet: return "the deck has no document stylesheet"
            case .notAStyle(let id): return "\(id) is not a style this deck holds"
            }
        }
    }

    /// The document's stylesheet: in `Index/DocumentStylesheet.iwa`, or with a locator suffix.
    public var documentStylesheet: UInt64? {
        var found: UInt64?
        for id in store.identifiers where store.record(for: id)?.info.messageInfos.first?.type == 401 {
            guard let component = store.entry(for: id)?.component else { continue }
            if component == "Index/DocumentStylesheet.iwa" { return id }
            if component.hasPrefix("Index/DocumentStylesheet-") && found == nil { found = id }
        }
        return found
    }

    /// A shape style variation over `parent` (a `TSWP.ShapeStyleArchive`) setting what is given:
    /// a fill (`.some(nil)` for none), a stroke, the text's vertical alignment and padding.
    public mutating func shapeStyleVariation(over parent: UInt64, fill: TSD_FillArchive?? = nil, stroke: TSD_StrokeArchive? = nil,
                                             verticalAlignment: TSWP_ShapeStylePropertiesArchive.VerticalAlignmentType? = nil,
                                             padding: TSWP_PaddingArchive? = nil) throws -> UInt64 {
        var style = TSWP_ShapeStyleArchive()
        var tsd = TSD_ShapeStylePropertiesArchive()
        var count: UInt32 = 0
        if let fill {
            if let fill { tsd.fill = fill } else { tsd.fill = TSD_FillArchive() }
            count += 1
        }
        if let stroke { tsd.stroke = stroke; count += 1 }
        style.super.shapeProperties = tsd
        style.super.overrideCount = count
        var wp = TSWP_ShapeStylePropertiesArchive()
        var wpCount: UInt32 = 0
        if let verticalAlignment { wp.verticalAlignment = verticalAlignment; wpCount += 1 }
        if let padding { wp.padding = padding; wpCount += 1 }
        style.shapeProperties = wp
        style.overrideCount = wpCount
        return try addVariation(over: parent) { base in
            style.super.super = base
            return try style.serializedData(partial: true)
        }
    }

    /// A paragraph style variation over `parent` (a `TSWP.ParagraphStyleArchive`) with these
    /// character and paragraph properties.
    public mutating func paragraphStyleVariation(over parent: UInt64, character: TSWP_CharacterStylePropertiesArchive,
                                                 paragraph: TSWP_ParagraphStylePropertiesArchive) throws -> UInt64 {
        var style = TSWP_ParagraphStyleArchive()
        style.charProperties = character
        style.paraProperties = paragraph
        style.overrideCount = UInt32(try character.serializedData(partial: true).isEmpty ? 0 : 1)
            + UInt32(try paragraph.serializedData(partial: true).isEmpty ? 0 : 1)
        return try addVariation(over: parent) { base in
            style.super = base
            return try style.serializedData(partial: true)
        }
    }

    /// Writes a new variation record over `parent` in the stylesheet's component (its header
    /// copied from the parent's, so the type and version are Keynote's; reference lists are
    /// derived at save) and registers it with the stylesheet.
    mutating func addVariation(over parent: UInt64, payload: (TSS_StyleArchive) throws -> Data) throws -> UInt64 {
        guard let stylesheet = documentStylesheet, var sheet = decoded(TSS_StylesheetArchive.self, stylesheet),
              let component = store.entry(for: stylesheet)?.component, var metadata = packageMetadata else {
            throw StyleVariationFailure.noStylesheet
        }
        guard let parentRecord = store.record(for: parent), let parentInfo = parentRecord.info.messageInfos.first else {
            throw StyleVariationFailure.notAStyle(parent)
        }
        var base = TSS_StyleArchive()
        base.parent = .with { $0.identifier = parent }
        base.isVariation = true
        base.stylesheet = .with { $0.identifier = stylesheet }
        let bytes = try payload(base)

        var allocator = IDAllocator(seed: max(store.highestIdentifier, metadata.lastObjectIdentifier) + 1)
        let id = allocator.allocate()
        var info = parentRecord.info
        info.setIdentifier(id)
        // One message: the parent's type and version, no field infos (they describe the parent's
        // own payload), the new length, and the one strong reference a variation holds (its
        // parent; the stylesheet is weak), as Keynote lists it.
        var message = try MessageInfo(fields: parentInfo.fields.filter { $0.number != MessageInfo.fieldInfosField })
        message.setLength(UInt32(bytes.count))
        message.setObjectReferences([parent])
        message.setDataReferences([])
        info.messageInfos = [message]
        store.append(ArchiveRecord(info: info, payloads: [bytes], isDirty: true), to: component)

        sheet.styles.append(.with { $0.identifier = id })
        if let i = sheet.parentToChildrenStyleMap.firstIndex(where: { $0.parent.identifier == parent }) {
            sheet.parentToChildrenStyleMap[i].children.append(.with { $0.identifier = id })
        } else {
            sheet.parentToChildrenStyleMap.append(.with {
                $0.parent = .with { $0.identifier = parent }
                $0.children = [.with { $0.identifier = id }]
            })
        }
        try replacePayload(of: stylesheet, with: try sheet.serializedData(partial: true))
        metadata.lastObjectIdentifier = max(metadata.lastObjectIdentifier, allocator.highWaterMark)
        try replacePayload(of: 2, with: try metadata.serializedData(partial: true))
        return id
    }
}
