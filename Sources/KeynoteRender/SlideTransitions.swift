import Foundation
import IWASchema
import KeynoteGraph

/// How Keynote moves from a slide to the next: the slide's own transition.
public struct SlideTransition: Sendable, Equatable {
    /// Keynote's effect ("apple:dissolve", "apple:push", "apple:magic-move-implied-motion-path", …).
    public var effect: String
    public var duration: Double
    /// Keynote's direction code (11 left to right, 12 right to left, 13 top to bottom, 14 bottom
    /// to top), when the effect has one.
    public var direction: Int?
    /// The transition starts by itself, `delay` seconds after the slide's builds end.
    public var automatic: Bool
    public var delay: Double

    public var isMagicMove: Bool { effect.hasPrefix("apple:magic-move") }
}

extension KeynoteRenderer {
    /// The transition from `slide` to the next; nil when it has none (Keynote's "none").
    public func transition(onSlide slide: UInt64) -> SlideTransition? {
        guard let archive = document.decoded(KN_SlideArchive.self, slide), archive.hasTransition else { return nil }
        let a = archive.transition.attributes.animationAttributes
        guard a.hasEffect, !a.effect.isEmpty, a.effect != "none" else { return nil }
        return SlideTransition(effect: a.effect, duration: a.hasDuration ? max(0, a.duration) : 1, direction: a.hasDirection ? Int(a.direction) : nil,
                               automatic: a.isAutomatic, delay: max(0, a.delay))
    }

    /// The objects Magic Move carries from `from` to `to`: on each slide its own drawables, in z
    /// order, paired when they show the same thing (the same picture; the same text in the same
    /// kind of object; a shape of the same style and kind of outline, at any size). Each object pairs once.
    public func magicMovePairs(from: UInt64, to: UInt64) -> [(from: SlideDrawable, to: SlideDrawable)] {
        let a = drawables(onSlide: from), b = drawables(onSlide: to)
        var available = Dictionary(grouping: b.indices, by: { signature(b[$0]) })
        var pairs = [(from: SlideDrawable, to: SlideDrawable)]()
        for d in a {
            guard let key = signature(d), var candidates = available[key], !candidates.isEmpty else { continue }
            pairs.append((d, b[candidates.removeFirst()]))
            available[key] = candidates
        }
        return pairs
    }

    /// What makes two objects the same thing for Magic Move; nil for what it does not carry.
    func signature(_ d: SlideDrawable) -> String? {
        switch d.kind {
        case .image:
            guard let image = document.decoded(TSD_ImageArchive.self, d.id), image.hasData else { return nil }
            return "image:\(image.data.identifier)"
        case .movie:
            guard let movie = document.decoded(TSD_MovieArchive.self, d.id), movie.hasMovieData else { return nil }
            return "movie:\(movie.movieData.identifier)"
        case .text, .shape, .placeholder, .line:
            let text = d.storage.flatMap { document.storageText($0) } ?? ""
            if !text.isEmpty { return "\(d.kind == .placeholder ? "text" : d.kind.rawValue)-text:\(text)" }
            guard let info = document.decoded(TSWP_ShapeInfoArchive.self, d.id) ?? document.decoded(KN_PlaceholderArchive.self, d.id)?.super,
                  info.super.hasStyle else { return nil }
            // The outline's kind, not its size: Magic Move resizes.
            let p = info.super.pathsource
            let outline = p.hasScalarPathSource ? "scalar\(p.scalarPathSource.type.rawValue)" : p.hasPointPathSource ? "point\(p.pointPathSource.type.rawValue)"
                : p.hasCalloutPathSource ? "callout" : p.hasConnectionLinePathSource ? "connection" : p.hasBezierPathSource || p.hasEditableBezierPathSource ? "bezier" : "-"
            return "\(d.kind.rawValue):\(info.super.style.identifier):\(outline)"
        default:
            return nil
        }
    }

    /// Slide `slide` with only `drawables` of its own, on nothing (a Magic Move object's layer).
    public func render(slide: UInt64, only drawables: Set<UInt64>) -> RenderedSlide {
        render(slide: slide, hiding: ([], [:]), only: drawables)
    }

    /// Slide `slide` without `drawables` (what Magic Move leaves behind).
    public func render(slide: UInt64, without drawables: Set<UInt64>) -> RenderedSlide {
        render(slide: slide, hiding: (drawables, [:]))
    }
}
