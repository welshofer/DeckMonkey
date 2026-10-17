import Foundation
import IWASchema
import KeynoteGraph
import SwiftProtobuf

/// Keynote styles are chains: a style names a parent, and a property message holds only the
/// fields that style overrides (a field set to its `…_null` twin overrides it with nothing). A
/// property's value is the first one met walking from the style towards the root.
struct StyleResolver {
    let document: KeynoteDocument
    static let maximumDepth = 32

    func chain<M: SwiftProtobuf.Message>(_ type: M.Type, from id: UInt64, style: (M) -> TSS_StyleArchive) -> [M] {
        var out = [M](), seen = Set<UInt64>(), next: UInt64? = id
        while let current = next, out.count < Self.maximumDepth, seen.insert(current).inserted,
              let archive = document.decoded(M.self, current) {
            out.append(archive)
            let s = style(archive)
            next = s.hasParent ? s.parent.identifier : nil
        }
        return out
    }

    static func first<M, V>(_ chain: [M], _ has: (M) -> Bool, _ value: (M) -> V) -> V? {
        chain.first(where: has).map(value)
    }

    // MARK: Shapes

    /// What a shape style decides about the drawing: TSD properties for every shape, and the
    /// text-layout properties a TSWP shape style adds.
    struct ShapeLook {
        var fill: TSD_FillArchive?
        var stroke: TSD_StrokeArchive?
        var opacity: Double = 1
        var shadow: TSD_ShadowArchive?
        var headLineEnd: TSD_LineEndArchive?
        var tailLineEnd: TSD_LineEndArchive?
        var padding = (left: 0.0, top: 0.0, right: 0.0, bottom: 0.0)
        var verticalAlignment: TSWP_ShapeStylePropertiesArchive.VerticalAlignmentType = .kFrameAlignTop
        var shrinkToFit = false
        var columns = 1
        var columnGap = 0.0
        var paragraphStyle: UInt64?
        /// What "natural" alignment means here: a table puts numbers on the right.
        var naturalAlignment: TSWP_ParagraphStylePropertiesArchive.TextAlignmentType?
        /// False for a table cell's number or date: it stays on one line.
        var wraps = true
    }

    func shapeLook(_ styleID: UInt64?) -> ShapeLook {
        var look = ShapeLook()
        guard let styleID, let type = document.store.record(for: styleID)?.info.messageInfos.first?.type else { return look }
        let tsd: [TSD_ShapeStylePropertiesArchive]
        if type == Self.tswpShapeStyleType {
            let c = chain(TSWP_ShapeStyleArchive.self, from: styleID) { $0.super.super }
            tsd = c.map(\.super.shapeProperties)
            let p = c.map(\.shapeProperties)
            if let pad = Self.first(p, { $0.hasPadding || $0.hasPaddingNull }, { $0.hasPadding ? $0.padding : nil }), let pad {
                look.padding = (Double(pad.left), Double(pad.top), Double(pad.right), Double(pad.bottom))
            }
            look.verticalAlignment = Self.first(p, \.hasVerticalAlignment, \.verticalAlignment) ?? .kFrameAlignTop
            look.shrinkToFit = Self.first(p, \.hasShrinkToFit, \.shrinkToFit) ?? false
            if let columns = Self.first(p, { $0.hasColumns || $0.hasColumnsNull }, { $0.hasColumns ? $0.columns : nil }), let columns {
                if columns.hasEqualColumns {
                    look.columns = max(1, Int(columns.equalColumns.count))
                    look.columnGap = Double(columns.equalColumns.gap)
                }
            }
            look.paragraphStyle = Self.first(p, { $0.hasParagraphStyle || $0.hasParagraphStyleNull }, { $0.hasParagraphStyle ? $0.paragraphStyle.identifier : nil }) ?? nil
        } else if type == Self.tsdShapeStyleType {
            tsd = chain(TSD_ShapeStyleArchive.self, from: styleID) { $0.super }.map(\.shapeProperties)
        } else {
            return look
        }
        look.fill = Self.first(tsd, \.hasFill, \.fill)
        look.stroke = Self.first(tsd, \.hasStroke, \.stroke)
        look.opacity = Self.first(tsd, \.hasOpacity, { Double($0.opacity) }) ?? 1
        look.shadow = Self.first(tsd, \.hasShadow, \.shadow)
        look.headLineEnd = Self.first(tsd, \.hasHeadLineEnd, \.headLineEnd)
        look.tailLineEnd = Self.first(tsd, \.hasTailLineEnd, \.tailLineEnd)
        return look
    }

    /// A media (image, movie) style's stroke and opacity.
    func mediaLook(_ styleID: UInt64?) -> (stroke: TSD_StrokeArchive?, opacity: Double, shadow: TSD_ShadowArchive?) {
        guard let styleID else { return (nil, 1, nil) }
        let p = chain(TSD_MediaStyleArchive.self, from: styleID) { $0.super }.map(\.mediaProperties)
        return (Self.first(p, \.hasStroke, \.stroke), Self.first(p, \.hasOpacity, { Double($0.opacity) }) ?? 1, Self.first(p, \.hasShadow, \.shadow))
    }

    /// A slide style's background fill and placeholder visibility.
    struct SlideLook {
        var fill: TSD_FillArchive?
        var titleVisible = true, bodyVisible = true, objectVisible = true, slideNumberVisible = false
    }

    func slideLook(_ styleID: UInt64?) -> SlideLook {
        var look = SlideLook()
        guard let styleID else { return look }
        let p = chain(KN_SlideStyleArchive.self, from: styleID) { $0.super }.map(\.slideProperties)
        look.fill = Self.first(p, \.hasFill, \.fill)
        look.titleVisible = Self.first(p, \.hasTitlePlaceholderVisibility, \.titlePlaceholderVisibility) ?? true
        look.bodyVisible = Self.first(p, \.hasBodyPlaceholderVisibility, \.bodyPlaceholderVisibility) ?? true
        look.objectVisible = Self.first(p, \.hasObjectPlaceholderVisibility, \.objectPlaceholderVisibility) ?? true
        look.slideNumberVisible = Self.first(p, \.hasSlideNumberPlaceholderVisibility, \.slideNumberPlaceholderVisibility) ?? false
        return look
    }

    static let tswpShapeStyleType: UInt32 = 2025
    static let tsdShapeStyleType: UInt32 = 3015
}
