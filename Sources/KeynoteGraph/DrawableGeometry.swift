import Foundation
import IWASchema
import SwiftProtobuf

/// Moving and resizing a drawable that sits directly on a slide: its geometry, and what the
/// geometry's size governs (a path source's natural size and points, an image's mask), the way
/// Keynote stores a drawable it has moved or resized itself. Rotated drawables, groups and their
/// members, tables (`setTableFrame`) and charts are refused.
extension KeynoteDocument {
    public enum DrawableGeometryFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case notMovable(UInt64, String)
        case invalidFrame

        public var description: String {
            switch self {
            case let .notMovable(id, why): return "object \(id) cannot be moved or resized here: \(why)"
            case .invalidFrame: return "the frame must be finite, at most 100,000 points, and at least 1 point wide and high"
            }
        }
    }

    /// Moves drawable `id` by `dx`, `dy` points.
    public mutating func moveDrawable(_ id: UInt64, dx: Double, dy: Double) throws {
        guard let frame = movableFrame(id) else { throw DrawableGeometryFailure.notMovable(id, "not a shape, text box, placeholder, image or movie on a slide") }
        try setDrawableFrame(id, Frame(x: frame.x + dx, y: frame.y + dy, width: frame.width, height: frame.height))
    }

    /// The frame of a drawable this API can move: on a slide, unrotated, of a supported kind. A
    /// cropped image's frame is what shows, its mask's (as Keynote's own inspector and AppleScript
    /// give it), not the whole picture behind the crop.
    public func movableFrame(_ id: UInt64) -> Frame? {
        guard let (drawable, _) = drawableArchive(id), drawable.hasGeometry, drawable.geometry.angle == 0,
              let parent = drawable.hasParent ? drawable.parent.identifier : nil,
              store.record(for: parent)?.info.messageInfos.first?.type == Self.slideType else { return nil }
        let g = drawable.geometry
        if let mask = mask(of: id) {
            let m = mask.super.geometry
            return Frame(x: Double(g.position.x + m.position.x), y: Double(g.position.y + m.position.y), width: Double(m.size.width), height: Double(m.size.height))
        }
        return Frame(x: Double(g.position.x), y: Double(g.position.y), width: Double(g.size.width), height: Double(g.size.height))
    }

    /// The unrotated mask of image `id`, if it has one.
    func mask(of id: UInt64) -> TSD_MaskArchive? {
        guard store.record(for: id)?.info.messageInfos.first?.type == Self.imageType,
              let image = decoded(TSD_ImageArchive.self, id), image.hasMask,
              let mask = decoded(TSD_MaskArchive.self, image.mask.identifier), mask.super.hasGeometry, mask.super.geometry.angle == 0 else { return nil }
        return mask
    }

    /// Places drawable `id` at `frame` (slide points, unrotated).
    public mutating func setDrawableFrame(_ id: UInt64, _ frame: Frame) throws {
        let values = [frame.x, frame.y, frame.width, frame.height]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 100_000 }) else { throw DrawableGeometryFailure.invalidFrame }
        guard let old = movableFrame(id), let type = store.record(for: id)?.info.messageInfos.first?.type else {
            throw DrawableGeometryFailure.notMovable(id, "not an unrotated drawable directly on a slide")
        }
        // A text box that sizes itself to its text keeps 0 × 0 when it only moves; given a size,
        // it becomes a box of that size, as Keynote makes it when one is dragged wider.
        // (A box with only a width keeps its automatic height the same way.)
        let staysSelfSizing = old.height == 0 && frame.height == 0 && frame.width == old.width
        guard staysSelfSizing || (frame.width >= 1 && frame.height >= 1) else { throw DrawableGeometryFailure.invalidFrame }
        let sx = old.width > 0 ? frame.width / old.width : 1, sy = old.height > 0 ? frame.height / old.height : 1
        func place(_ g: inout TSD_GeometryArchive) {
            g.position = TSP_Point.with { $0.x = Float(frame.x); $0.y = Float(frame.y) }
            g.size = TSP_Size.with { $0.width = Float(frame.width); $0.height = Float(frame.height) }
        }
        switch type {
        case Self.placeholderType:
            guard var p = decoded(KN_PlaceholderArchive.self, id) else { throw DrawableGeometryFailure.notMovable(id, "unreadable") }
            place(&p.super.super.super.geometry)
            if p.super.super.hasPathsource { Self.scale(&p.super.super.pathsource, sx, sy, to: frame) }
            try replacePayload(of: id, with: try p.serializedData(partial: true))
        case Self.shapeInfoType:
            guard var s = decoded(TSWP_ShapeInfoArchive.self, id) else { throw DrawableGeometryFailure.notMovable(id, "unreadable") }
            place(&s.super.super.geometry)
            if s.super.hasPathsource { Self.scale(&s.super.pathsource, sx, sy, to: frame) }
            try replacePayload(of: id, with: try s.serializedData(partial: true))
        case Self.tsdShapeType:
            guard var s = decoded(TSD_ShapeArchive.self, id) else { throw DrawableGeometryFailure.notMovable(id, "unreadable") }
            place(&s.super.geometry)
            if s.hasPathsource { Self.scale(&s.pathsource, sx, sy, to: frame) }
            try replacePayload(of: id, with: try s.serializedData(partial: true))
        case Self.imageType:
            guard var i = decoded(TSD_ImageArchive.self, id) else { throw DrawableGeometryFailure.notMovable(id, "unreadable") }
            if let mask = mask(of: id) {
                // `frame` is where the crop shows: the picture scales with it and moves so the
                // mask's corner lands on the frame's.
                let m = mask.super.geometry, g = i.super.geometry
                let full = Frame(x: frame.x - Double(m.position.x) * sx, y: frame.y - Double(m.position.y) * sy,
                                 width: Double(g.size.width) * sx, height: Double(g.size.height) * sy)
                i.super.geometry.position = TSP_Point.with { $0.x = Float(full.x); $0.y = Float(full.y) }
                i.super.geometry.size = TSP_Size.with { $0.width = Float(full.width); $0.height = Float(full.height) }
            } else {
                place(&i.super.geometry)
            }
            if i.hasOriginalSize { i.originalSize = TSP_Size.with { $0.width = Float(Double(i.originalSize.width) * sx); $0.height = Float(Double(i.originalSize.height) * sy) } }
            // A mask sits in the image's frame coordinates: it scales with the image.
            if i.hasMask, var mask = decoded(TSD_MaskArchive.self, i.mask.identifier), mask.super.hasGeometry {
                let g = mask.super.geometry
                let maskFrame = Frame(x: Double(g.position.x) * sx, y: Double(g.position.y) * sy, width: Double(g.size.width) * sx, height: Double(g.size.height) * sy)
                mask.super.geometry.position = TSP_Point.with { $0.x = Float(maskFrame.x); $0.y = Float(maskFrame.y) }
                mask.super.geometry.size = TSP_Size.with { $0.width = Float(maskFrame.width); $0.height = Float(maskFrame.height) }
                if mask.hasPathsource { Self.scale(&mask.pathsource, sx, sy, to: maskFrame) }
                try replacePayload(of: i.mask.identifier, with: try mask.serializedData(partial: true))
            }
            try replacePayload(of: id, with: try i.serializedData(partial: true))
        case Self.movieType:
            guard var m = decoded(TSD_MovieArchive.self, id) else { throw DrawableGeometryFailure.notMovable(id, "unreadable") }
            place(&m.super.geometry)
            try replacePayload(of: id, with: try m.serializedData(partial: true))
        default:
            throw DrawableGeometryFailure.notMovable(id, "type \(type)")
        }
    }

    /// The drawable archive of a supported kind, and its type.
    func drawableArchive(_ id: UInt64) -> (TSD_DrawableArchive, UInt32)? {
        guard let type = store.record(for: id)?.info.messageInfos.first?.type else { return nil }
        switch type {
        case Self.placeholderType: return decoded(KN_PlaceholderArchive.self, id).map { ($0.super.super.super, type) }
        case Self.shapeInfoType: return decoded(TSWP_ShapeInfoArchive.self, id).map { ($0.super.super, type) }
        case Self.tsdShapeType: return decoded(TSD_ShapeArchive.self, id).map { ($0.super, type) }
        case Self.imageType: return decoded(TSD_ImageArchive.self, id).map { ($0.super, type) }
        case Self.movieType: return decoded(TSD_MovieArchive.self, id).map { ($0.super, type) }
        default: return nil
        }
    }

    /// A path source resized with its drawable: its natural size becomes the new size and a
    /// bezier's points scale with it; parametric shapes (rounded rectangles, arrows, stars) keep
    /// their parameters and redraw at the new natural size.
    static func scale(_ source: inout TSD_PathSourceArchive, _ sx: Double, _ sy: Double, to frame: Frame) {
        let size = TSP_Size.with { $0.width = Float(frame.width); $0.height = Float(frame.height) }
        func scaled(_ path: TSP_Path) -> TSP_Path {
            var p = path
            for e in p.elements.indices {
                for q in p.elements[e].points.indices {
                    p.elements[e].points[q].x = Float(Double(p.elements[e].points[q].x) * sx)
                    p.elements[e].points[q].y = Float(Double(p.elements[e].points[q].y) * sy)
                }
            }
            return p
        }
        if source.hasBezierPathSource {
            source.bezierPathSource.naturalSize = TSP_Size.with { $0.width = Float(Double(source.bezierPathSource.naturalSize.width) * sx); $0.height = Float(Double(source.bezierPathSource.naturalSize.height) * sy) }
            if source.bezierPathSource.hasPath { source.bezierPathSource.path = scaled(source.bezierPathSource.path) }
        }
        if source.hasScalarPathSource { source.scalarPathSource.naturalSize = size }
        if source.hasPointPathSource {
            source.pointPathSource.naturalSize = size
        }
        if source.hasCalloutPathSource { source.calloutPathSource.naturalSize = size }
        if source.hasEditableBezierPathSource {
            source.editableBezierPathSource.naturalSize = size
            for s in source.editableBezierPathSource.subpaths.indices {
                for n in source.editableBezierPathSource.subpaths[s].nodes.indices {
                    var node = source.editableBezierPathSource.subpaths[s].nodes[n]
                    for kp in [\TSD_EditableBezierPathSourceArchive.Node.inControlPoint, \.nodePoint, \.outControlPoint] {
                        node[keyPath: kp].x = Float(Double(node[keyPath: kp].x) * sx)
                        node[keyPath: kp].y = Float(Double(node[keyPath: kp].y) * sy)
                    }
                    source.editableBezierPathSource.subpaths[s].nodes[n] = node
                }
            }
        }
    }

    static let tsdShapeType: UInt32 = 3004
}
