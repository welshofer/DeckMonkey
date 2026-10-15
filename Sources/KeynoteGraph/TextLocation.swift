import Foundation
import IWASchema
import SwiftProtobuf

/// Where a text storage appears: its owning shape, that shape's frame on the slide, and the slide's
/// page in Keynote's PDF export. Gate 1 uses it to require that a replacement changes pixels only
/// inside the replaced text's frame (docs/spec.md §12).
extension KeynoteDocument {
    public struct TextLocation: Equatable, Sendable {
        public var storage: UInt64
        /// The `TSWP.ShapeInfoArchive` (a text box, or a placeholder's shape) that owns the storage.
        public var shape: UInt64
        public var slide: UInt64?
        /// 1-based page in the PDF export (non-skipped slides in slide-tree order); nil when the
        /// slide is skipped or not in the tree (a master).
        public var page: Int?
        /// The shape's frame in slide points, origin top-left; nil when the shape has no geometry of
        /// its own, sits inside a group (whose transform this does not apply), or sizes itself to its
        /// text (a free text box stores size 0×0 and its centre; Keynote computes the frame).
        public var frame: Frame?
    }

    public struct Frame: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double, angle: Double
    }

    static let shapeInfoType: UInt32 = 2011
    static let placeholderType: UInt32 = 7
    static let slideType: UInt32 = 5
    static let showType: UInt32 = 2

    func decoded<M: SwiftProtobuf.Message>(_ type: M.Type, _ identifier: UInt64) -> M? {
        guard let payload = store.record(for: identifier)?.payloads.first else { return nil }
        return try? M(serializedBytes: payload, extensions: Schema.extensions, partial: true)
    }

    /// Slide identifier → 1-based PDF page, for every non-skipped slide in slide-tree order.
    public var pageOfSlide: [UInt64: Int] {
        guard let showID = store.identifiers.first(where: { store.record(for: $0)?.info.messageInfos.first?.type == Self.showType }),
              let show = decoded(KN_ShowArchive.self, showID) else { return [:] }
        // Older decks list every node in slideTree.slides, children included, as well as under
        // their parent: each node counts once, at its first visit.
        var pages = [UInt64: Int](), page = 0, visited = Set<UInt64>()
        func visit(_ node: UInt64) {
            guard visited.insert(node).inserted, let n = decoded(KN_SlideNodeArchive.self, node) else { return }
            if !n.isSkipped, n.hasSlide {
                page += 1
                pages[n.slide.identifier] = page
            }
            n.children.forEach { visit($0.identifier) }
        }
        // Keynote 6.5 kept the tree under a root node with no slide of its own (rootSlideNode, now
        // deprecated); later files list the nodes in `slides`.
        if show.slideTree.slides.isEmpty, show.slideTree.hasRootSlideNode {
            visit(show.slideTree.rootSlideNode.identifier)
        } else {
            show.slideTree.slides.forEach { visit($0.identifier) }
        }
        return pages
    }

    /// The page and frame of a drawable placed directly on a slide: an image (`TSD.ImageArchive`), a
    /// movie or audio clip (`TSD.MovieArchive`), or a shape (`TSWP.ShapeInfoArchive`, a placeholder).
    public func location(ofDrawable id: UInt64) -> (slide: UInt64?, page: Int?, frame: Frame?)? {
        guard let type = store.record(for: id)?.info.messageInfos.first?.type else { return nil }
        let drawable: TSD_DrawableArchive
        switch type {
        case Self.imageType: guard let i = decoded(TSD_ImageArchive.self, id) else { return nil }; drawable = i.super
        case Self.movieType: guard let m = decoded(TSD_MovieArchive.self, id) else { return nil }; drawable = m.super
        case Self.shapeInfoType: guard let s = decoded(TSWP_ShapeInfoArchive.self, id) else { return nil }; drawable = s.super.super
        case Self.placeholderType: guard let p = decoded(KN_PlaceholderArchive.self, id) else { return nil }; drawable = p.super.super.super
        default: return nil
        }
        return frame(of: drawable)
    }

    /// Effects of an image's own media style that paint outside its frame.
    public struct MediaEffects: Equatable, Sendable {
        public var reflection = false, shadow = false, stroke = false
    }

    public func mediaEffects(ofImage id: UInt64) -> MediaEffects {
        guard let image = decoded(TSD_ImageArchive.self, id), image.hasStyle,
              let style = decoded(TSD_MediaStyleArchive.self, image.style.identifier), style.hasMediaProperties else { return MediaEffects() }
        let p = style.mediaProperties
        return MediaEffects(reflection: p.hasReflection, shadow: p.hasShadow, stroke: p.hasStroke)
    }

    func frame(of drawable: TSD_DrawableArchive) -> (slide: UInt64?, page: Int?, frame: Frame?) {
        let parent = drawable.hasParent ? drawable.parent.identifier : nil
        let onSlide = parent.flatMap { store.record(for: $0)?.info.messageInfos.first?.type } == Self.slideType
        var frame: Frame?
        if onSlide, drawable.hasGeometry, drawable.geometry.hasPosition, drawable.geometry.hasSize,
           drawable.geometry.size.width > 0, drawable.geometry.size.height > 0 {
            let g = drawable.geometry
            frame = Frame(x: Double(g.position.x), y: Double(g.position.y), width: Double(g.size.width),
                          height: Double(g.size.height), angle: Double(g.angle))
        }
        let slide = onSlide ? parent : nil
        return (slide, slide.flatMap { pageOfSlide[$0] }, frame)
    }

    /// The location of `storage`, or nil if no shape owns it (a table cell, a note, a master).
    public func location(of storage: UInt64) -> TextLocation? {
        for id in store.identifiers {
            guard let type = store.record(for: id)?.info.messageInfos.first?.type else { continue }
            let shapeInfo: TSWP_ShapeInfoArchive?
            switch type {
            case Self.shapeInfoType: shapeInfo = decoded(TSWP_ShapeInfoArchive.self, id)
            case Self.placeholderType: shapeInfo = decoded(KN_PlaceholderArchive.self, id)?.super
            default: continue
            }
            // Older Keynotes held a shape's text in the field now named deprecated_storage.
            guard let info = shapeInfo,
                  (info.hasOwnedStorage && info.ownedStorage.identifier == storage)
                    || (info.hasDeprecatedStorage && info.deprecatedStorage.identifier == storage) else { continue }
            let at = frame(of: info.super.super)
            return TextLocation(storage: storage, shape: id, slide: at.slide, page: at.page, frame: at.frame)
        }
        return nil
    }
}
