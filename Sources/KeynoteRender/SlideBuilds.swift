import Foundation
import IWASchema
import KeynoteGraph

/// One step of a slide's build order: a build (in, out or an action) of one drawable, or of one
/// part of it (a paragraph of text delivered by paragraph).
public struct SlideBuildChunk: Sendable, Equatable {
    public enum Kind: String, Sendable { case buildIn = "in", buildOut = "out", action }
    public enum Trigger: String, Sendable { case click, afterPrevious, withPrevious }

    public var build: UInt64
    public var drawable: UInt64
    public var kind: Kind
    /// Keynote's effect name ("apple:dissolve", "apple:movie-start", …).
    public var effect: String
    public var trigger: Trigger
    /// Seconds after its trigger, and how long it plays.
    public var delay: Double
    public var duration: Double
    /// The paragraphs (indices in the drawable's text) this chunk brings in or takes out; nil for
    /// the whole drawable.
    public var paragraphs: [Int]?
    /// Keynote's direction code: 11 left to right, 12 right to left, 13 top to bottom, 14 bottom
    /// to top (moves, wipes, pushes); 43 and 44 zoom up and down.
    public var direction: Int?
    /// An action's motion: x, y pairs along its path in points from where it starts.
    public var path: [Double]?
    /// An action's turn in degrees, clockwise positive; its end opacity (0…1) and scale.
    public var rotation: Double?, opacity: Double?, scale: Double?
}

/// A slide's builds as stages: stage 0 is the slide before any build, and each click (or, for a
/// slide whose first build is automatic, its appearance) plays the next group of chunks to the
/// next stage. This is what Keynote prints with "each stage of builds" (`oracle.sh --stages`).
public struct SlideBuildSequence: Sendable, Equatable {
    public var chunks: [SlideBuildChunk]
    /// Ranges of `chunks`, one per stage after the first: a click, then the automatic chunks after it.
    public var groups: [Range<Int>]
    /// The first group plays when the slide appears, not on a click.
    public var startsAutomatically: Bool
    public var stageCount: Int { groups.count + 1 }

    public static let none = SlideBuildSequence(chunks: [], groups: [], startsAutomatically: false)
}

extension KeynoteRenderer {
    /// The slide's build order as Keynote plays it: its build chunks in order, each saying whether
    /// a click or the previous chunk starts it, then a click for each movie that waits for one
    /// (`build` 0, effect "apple:movie-start").
    public func builds(onSlide slide: UInt64) -> SlideBuildSequence {
        guard let archive = document.decoded(KN_SlideArchive.self, slide) else { return .none }
        var builds = [UInt64: KN_BuildArchive]()
        for ref in archive.builds.prefix(2_000) { builds[ref.identifier] = document.decoded(KN_BuildArchive.self, ref.identifier) }

        // The chunks: referenced records, or (Keynote 6.5 and before) kept inline in the slide;
        // Keynote 15 reads the inline ones as they are and writes them back as records.
        let stored = archive.buildChunks.isEmpty
            ? Array(archive.buildChunkArchives.prefix(10_000))
            : archive.buildChunks.prefix(10_000).compactMap { document.decoded(KN_BuildChunkArchive.self, $0.identifier) }
        // A build delivered in parts: its chunk identifiers in order name its parts in order.
        var partIDs = [UInt64: [Int32]]()
        for c in stored { partIDs[c.build.identifier, default: []].append(c.buildChunkIdentifier.buildChunkID) }
        for (key, ids) in partIDs { partIDs[key] = ids.sorted() }
        var chunks = [SlideBuildChunk]()
        // Each build's parts, worked out once however many chunks name it.
        var partsOf = [UInt64: [[Int]]?]()
        var seen = [UInt64: Int]()
        for c in stored {
            guard let build = builds[c.build.identifier] else { continue }
            let trigger: SlideBuildChunk.Trigger = !c.automatic ? .click : c.referent ? .afterPrevious : .withPrevious
            var paragraphs: [Int]?
            if partsOf[c.build.identifier] == nil { partsOf[c.build.identifier] = .some(self.parts(of: build)) }
            if let parts = partsOf[c.build.identifier] ?? nil {
                // Keynote 6.5's inline chunks of a build all carry the same identifier: their order
                // names the parts.
                let ids = partIDs[c.build.identifier] ?? []
                let rank = Set(ids).count == ids.count ? ids.firstIndex(of: c.buildChunkIdentifier.buildChunkID)
                    : seen[c.build.identifier, default: 0]
                if let rank { paragraphs = parts.indices.contains(rank) ? parts[rank] : [] }
            }
            seen[c.build.identifier, default: 0] += 1
            chunks.append(chunk(build, id: c.build.identifier, trigger: trigger, delay: c.delay, duration: c.duration, paragraphs: paragraphs))
        }

        // A movie that neither plays as the slide appears nor has a Start Movie build waits for a
        // click of its own, which Keynote counts as a stage (the picture does not change).
        for movie in movies(onSlide: slide) where !movie.autoPlay && !movie.startsOnBuild {
            chunks.append(SlideBuildChunk(build: 0, drawable: movie.id, kind: .action, effect: "apple:movie-start", trigger: .click,
                                          delay: 0, duration: 0, paragraphs: nil))
        }

        // Groups: a click starts one; automatic chunks join the group before them. A first chunk
        // that is automatic plays as the slide appears.
        var groups = [Range<Int>]()
        var start: Int?
        for (i, c) in chunks.enumerated() where c.trigger == .click || start == nil {
            if let s = start { groups.append(s..<i) }
            start = i
        }
        if let s = start { groups.append(s..<chunks.count) }
        // Bounded like everything else read from a file: a crafted slide cannot ask for more.
        groups = Array(groups.prefix(Self.maximumStages))
        return SlideBuildSequence(chunks: chunks, groups: groups, startsAutomatically: chunks.first.map { $0.trigger != .click } ?? false)
    }

    /// At most this many stages per slide (a click each: no real slide comes near).
    static let maximumStages = 1_000

    func chunk(_ build: KN_BuildArchive, id: UInt64, trigger: SlideBuildChunk.Trigger, delay: Double, duration: Double, paragraphs: [Int]?) -> SlideBuildChunk {
        let animation = build.attributes.animationAttributes
        // Movie builds (start, pause, stop) control playback: the movie is on the slide throughout.
        let movie = animation.effect.hasPrefix("apple:movie-")
        let kind: SlideBuildChunk.Kind = movie || animation.animationType == "Action" ? .action : animation.animationType == "Out" ? .buildOut : .buildIn
        var chunk = SlideBuildChunk(build: id, drawable: build.drawable.identifier, kind: kind, effect: animation.effect, trigger: trigger,
                                    delay: delay, duration: duration, paragraphs: paragraphs)
        if animation.hasDirection { chunk.direction = Int(animation.direction) }
        let a = build.attributes
        switch animation.effect {
        case "apple:action-motion-path":
            if a.hasActionMotionPathSource, let outline = Paths.outline(a.actionMotionPathSource) { chunk.path = Self.sampled(outline) }
        case "apple:action-rotation":
            chunk.rotation = a.actionRotationDirection == .kCounterclockwise ? -a.actionRotationAngle : a.actionRotationAngle
        case "apple:action-opacity":
            chunk.opacity = max(0, min(1, a.actionColorAlpha / 100))
        case "apple:action-scale":
            if a.actionScaleSize > 0 { chunk.scale = a.actionScaleSize / 100 }
        default: break
        }
        return chunk
    }

    /// Points along an outline, from its first point (curves in 16 steps), at most 4,096 numbers.
    static func sampled(_ outline: Outline) -> [Double]? {
        var points = [Double](), last: (Double, Double)?
        for command in outline.commands {
            switch command {
            case let .move(x, y), let .line(x, y):
                points += [x, y]; last = (x, y)
            case let .quad(cx, cy, x, y):
                let p = last ?? (x, y)
                for i in 1...16 {
                    let t = Double(i) / 16, u = 1 - t
                    points += [u * u * p.0 + 2 * u * t * cx + t * t * x, u * u * p.1 + 2 * u * t * cy + t * t * y]
                }
                last = (x, y)
            case let .cubic(c1x, c1y, c2x, c2y, x, y):
                let p = last ?? (x, y)
                for i in 1...16 {
                    let t = Double(i) / 16, u = 1 - t
                    points += [u * u * u * p.0 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x,
                               u * u * u * p.1 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y]
                }
                last = (x, y)
            case .close: break
            }
            if points.count >= 4_096 { break }
        }
        guard points.count >= 4 else { return nil }
        let x0 = points[0], y0 = points[1]
        return points.prefix(4_096).enumerated().map { $0.offset % 2 == 0 ? $0.element - x0 : $0.element - y0 }
    }

    /// The paragraphs each part of a build delivered by paragraph or bullet holds (empty
    /// paragraphs are not parts; a bullet group is a top-level paragraph and those under it); nil
    /// for a build delivered whole.
    func parts(of build: KN_BuildArchive) -> [[Int]]? {
        let delivery = build.delivery.lowercased()
        guard delivery.hasPrefix("by paragraph") || delivery.hasPrefix("by bullet") || delivery.hasPrefix("by highlighted bullet") else { return nil }
        let id = build.drawable.identifier
        guard let info = document.decoded(TSWP_ShapeInfoArchive.self, id) ?? document.decoded(KN_PlaceholderArchive.self, id)?.super,
              info.hasOwnedStorage, let storage = document.decoded(TSWP_StorageArchive.self, info.ownedStorage.identifier) else { return nil }
        let units = Array(storage.text.joined().utf16.prefix(Canvas.maximumTextUnits))
        var paragraphs = [(range: Range<Int>, level: Int)]()
        let levels = storage.tableParaData.entries.prefix(Canvas.maximumEntries).sorted { $0.characterIndex < $1.characterIndex }
        var start = 0, next = 0, current = 0
        // Paragraph starts only increase: one pass over the sorted level entries.
        func level(at index: Int) -> Int {
            while next < levels.count, Int(levels[next].characterIndex) <= index { current = Int(levels[next].first); next += 1 }
            return current
        }
        for (i, u) in units.enumerated() where u == 0x0A || u == 0x0D || u == 0x2029 {
            paragraphs.append((start..<i, level(at: start))); start = i + 1
        }
        paragraphs.append((start..<units.count, level(at: start)))
        let filled = paragraphs.indices.filter { !paragraphs[$0].range.isEmpty }
        guard delivery.hasPrefix("by bullet group") else { return filled.map { [$0] } }
        var groups = [[Int]]()
        for i in filled {
            if paragraphs[i].level == 0 || groups.isEmpty { groups.append([i]) } else { groups[groups.count - 1].append(i) }
        }
        return groups
    }

    /// What is not drawn at `stage`, and which chunks have played to reach it.
    func hiding(slide: UInt64, stage: Int, of sequence: SlideBuildSequence) -> (Set<UInt64>, [UInt64: Set<Int>], [Int]) {
        var hiddenDrawables = Set<UInt64>()
        var hiddenParagraphs = [UInt64: Set<Int>]()
        var storages = [UInt64: UInt64]()
        func storage(_ drawable: UInt64) -> UInt64? {
            if let known = storages[drawable] { return known }
            let info = document.decoded(TSWP_ShapeInfoArchive.self, drawable) ?? document.decoded(KN_PlaceholderArchive.self, drawable)?.super
            let id = info.flatMap { $0.hasOwnedStorage ? $0.ownedStorage.identifier : nil }
            storages[drawable] = id
            return id
        }
        func set(_ c: SlideBuildChunk, visible: Bool) {
            if let paragraphs = c.paragraphs, let s = storage(c.drawable) {
                if visible { hiddenParagraphs[s, default: []].subtract(paragraphs) } else { hiddenParagraphs[s, default: []].formUnion(paragraphs) }
            } else if visible {
                hiddenDrawables.remove(c.drawable)
            } else {
                hiddenDrawables.insert(c.drawable)
            }
        }
        // What builds in starts hidden; then the chunks of the stages reached play in order.
        for c in sequence.chunks where c.kind == .buildIn { set(c, visible: false) }
        let played = sequence.groups.prefix(max(0, min(stage, sequence.groups.count))).flatMap { Array($0) }
        for i in played {
            let c = sequence.chunks[i]
            switch c.kind {
            case .buildIn: set(c, visible: true)
            case .buildOut: set(c, visible: false)
            case .action: break
            }
        }
        return (hiddenDrawables, hiddenParagraphs, played)
    }

    /// The slide's drawables above its lowest movie, at build stage `stage`, on nothing: the layer
    /// a host puts over the playing movie so what Keynote layers above it stays above it. Nil when
    /// the slide has no movie with a picture, or nothing above it.
    public func renderAboveMovies(slide: UInt64, stage: Int? = nil, of sequence: SlideBuildSequence? = nil) -> RenderedSlide? {
        let movies = self.movies(onSlide: slide).filter { !$0.audioOnly }
        guard let lowest = movies.first, let archive = document.decoded(KN_SlideArchive.self, slide) else { return nil }
        let order = (archive.drawablesZOrder.isEmpty ? archive.ownedDrawables : archive.drawablesZOrder).map(\.identifier)
        guard let index = order.firstIndex(of: lowest.id) else { return nil }
        let movieIDs = Set(movies.map(\.id))
        var hidden = Set<UInt64>(), paragraphs = [UInt64: Set<Int>]()
        if let stage {
            let sequence = sequence ?? builds(onSlide: slide)
            if !sequence.chunks.isEmpty { (hidden, paragraphs, _) = hiding(slide: slide, stage: stage, of: sequence) }
        }
        hidden.formUnion(movieIDs)
        guard order[(index + 1)...].contains(where: { !hidden.contains($0) }) else { return nil }
        return render(slide: slide, hiding: (hidden, paragraphs), above: lowest.id)
    }

    /// Slide `slide` at build stage `stage` (0: before any build; `stageCount - 1`: all played).
    /// Actions (moves, rotations) are not applied: their drawables stay where the slide puts them.
    public func render(slide: UInt64, stage: Int) -> RenderedSlide {
        render(slide: slide, stage: stage, of: builds(onSlide: slide))
    }

    /// As `render(slide:stage:)`, with the slide's `builds(onSlide:)` already worked out (a host
    /// drawing every stage computes it once).
    public func render(slide: UInt64, stage: Int, of sequence: SlideBuildSequence) -> RenderedSlide {
        guard !sequence.chunks.isEmpty else { return render(slide: slide) }
        let (hiddenDrawables, hiddenParagraphs, played) = hiding(slide: slide, stage: stage, of: sequence)
        let (actions, unapplied) = self.actions(onSlide: slide, played: played.map { sequence.chunks[$0] })
        var rendered = render(slide: slide, hiding: (hiddenDrawables, hiddenParagraphs), actions: actions)
        if unapplied { rendered.problems = (Set(rendered.problems).union(["build action (not applied)"])).sorted() }
        return rendered
    }

    /// Where the actions played so far leave each drawable, as an SVG transform about its frame's
    /// centre and an opacity: a motion path moves it by the path's end less its start, a rotation
    /// turns it (clockwise or not), Opacity and Scale set those; Jiggle, Bounce, Pop and Flip end
    /// where they began. `unapplied` when an action of another kind has played.
    func actions(onSlide slide: UInt64, played: [SlideBuildChunk]) -> (transforms: [UInt64: (transform: String, opacity: Double)], unapplied: Bool) {
        struct State { var dx = 0.0, dy = 0.0, turn = 0.0, scale = 1.0, opacity = 1.0 }
        var states = [UInt64: State](), order = [UInt64](), unapplied = false
        for c in played where c.kind == .action && !c.effect.hasPrefix("apple:movie-") {
            guard let build = document.decoded(KN_BuildArchive.self, c.build) else { continue }
            let a = build.attributes
            var state = states[c.drawable] ?? State()
            switch c.effect {
            case "apple:action-motion-path":
                guard a.hasActionMotionPathSource, let outline = Paths.outline(a.actionMotionPathSource),
                      let start = outline.commands.first.flatMap(Self.endPoint), let end = outline.commands.last(where: { Self.endPoint($0) != nil }).flatMap(Self.endPoint)
                else { unapplied = true; continue }
                state.dx += end.0 - start.0; state.dy += end.1 - start.1
            case "apple:action-rotation":
                state.turn += a.actionRotationDirection == .kCounterclockwise ? -a.actionRotationAngle : a.actionRotationAngle
            case "apple:action-opacity":
                state.opacity = max(0, min(1, a.actionColorAlpha / 100))
            case "apple:action-scale":
                if a.actionScaleSize > 0 { state.scale *= a.actionScaleSize / 100 }
            case "apple:action-jiggle", "apple:action-bounce", "apple:action-pop", "apple:action-flip", "apple:action-pulse", "apple:action-blink":
                break
            default:
                unapplied = true; continue
            }
            if states[c.drawable] == nil { order.append(c.drawable) }
            states[c.drawable] = state
        }
        guard !states.isEmpty else { return ([:], unapplied) }
        let frames = Dictionary(drawables(onSlide: slide).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = [UInt64: (transform: String, opacity: Double)]()
        for id in order {
            guard let state = states[id], let f = frames[id] else { unapplied = true; continue }
            let cx = f.x + f.width / 2, cy = f.y + f.height / 2
            var t = "translate(\(SVG.n(state.dx)) \(SVG.n(state.dy)))"
            if state.turn != 0 { t += " rotate(\(SVG.n(state.turn)) \(SVG.n(cx)) \(SVG.n(cy)))" }
            if state.scale != 1 { t += " translate(\(SVG.n(cx)) \(SVG.n(cy))) scale(\(SVG.n(state.scale))) translate(\(SVG.n(-cx)) \(SVG.n(-cy)))" }
            out[id] = (t, state.opacity)
        }
        return (out, unapplied)
    }

    static func endPoint(_ command: Outline.Command) -> (Double, Double)? {
        switch command {
        case let .move(x, y), let .line(x, y): return (x, y)
        case let .quad(_, _, x, y): return (x, y)
        case let .cubic(_, _, _, _, x, y): return (x, y)
        case .close: return nil
        }
    }

    /// One step's pictures for a host to animate (fade first is a dissolve of the whole stage): a
    /// backdrop, stage `stage` without what the step's chunks animate, and for each chunk a layer
    /// on nothing holding just its object (or its paragraphs) as it is when the chunk is seen:
    /// after an in-build, before an out-build or an action. Movie chunks have no layer.
    public func renderStep(slide: UInt64, to stage: Int, of sequence: SlideBuildSequence) -> SlideBuildStep? {
        guard stage >= 1, stage <= sequence.groups.count else { return nil }
        let group = sequence.groups[stage - 1]
        let animated = group.filter { !sequence.chunks[$0].effect.hasPrefix("apple:movie-") }
        let after = hiding(slide: slide, stage: stage, of: sequence), before = hiding(slide: slide, stage: stage - 1, of: sequence)
        var storages = [UInt64: (id: UInt64, count: Int)]()
        func storage(_ drawable: UInt64) -> (id: UInt64, count: Int)? {
            if let known = storages[drawable] { return known }
            let info = document.decoded(TSWP_ShapeInfoArchive.self, drawable) ?? document.decoded(KN_PlaceholderArchive.self, drawable)?.super
            guard let info, info.hasOwnedStorage, let text = document.decoded(TSWP_StorageArchive.self, info.ownedStorage.identifier) else { return nil }
            let units = text.text.joined().utf16.prefix(Canvas.maximumTextUnits)
            let entry = (info.ownedStorage.identifier, units.filter { $0 == 0x0A || $0 == 0x0D || $0 == 0x2029 }.count + 1)
            storages[drawable] = entry
            return entry
        }
        // The backdrop: the stage reached, less what is animated into or out of it.
        var hidden = after.0, paragraphs = after.1
        for i in animated {
            let c = sequence.chunks[i]
            if let parts = c.paragraphs, let s = storage(c.drawable) { paragraphs[s.id, default: []].formUnion(parts) } else { hidden.insert(c.drawable) }
        }
        let endActions = actions(onSlide: slide, played: sequence.groups.prefix(stage).flatMap { $0 }.map { sequence.chunks[$0] }).transforms
        let backdrop = render(slide: slide, hiding: (hidden, paragraphs), actions: endActions)
        var layers = [SlideBuildStep.Layer]()
        let earlier = sequence.groups.prefix(stage - 1).flatMap { $0 }
        for i in animated {
            let c = sequence.chunks[i]
            // Seen after an in-build; before an out-build or an action (an action's own change is
            // the host's to animate).
            let state = c.kind == .buildIn ? after : before
            let playedBefore = earlier + group.filter { $0 < i && !(sequence.chunks[$0].drawable == c.drawable && sequence.chunks[$0].kind == .action) }
            let moved = actions(onSlide: slide, played: playedBefore.map { sequence.chunks[$0] }).transforms
            var layerParagraphs = state.1
            if let parts = c.paragraphs, let s = storage(c.drawable) {
                layerParagraphs[s.id] = Set(0..<min(s.count, Canvas.maximumEntries)).subtracting(parts)
            }
            var hiddenHere = state.0
            hiddenHere.remove(c.drawable)
            let rendered = render(slide: slide, hiding: (hiddenHere, layerParagraphs), actions: moved, only: [c.drawable])
            layers.append(.init(chunk: i, rendered: rendered))
        }
        return SlideBuildStep(backdrop: backdrop, layers: layers)
    }
}

/// What `renderStep` draws for one step.
public struct SlideBuildStep: Sendable {
    public struct Layer: Sendable {
        /// The chunk (an index in the sequence's `chunks`) the layer belongs to.
        public var chunk: Int
        public var rendered: RenderedSlide
    }
    public var backdrop: RenderedSlide
    public var layers: [Layer]
}
