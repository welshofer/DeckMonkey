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
        return SlideBuildChunk(build: id, drawable: build.drawable.identifier, kind: kind, effect: animation.effect, trigger: trigger,
                               delay: delay, duration: duration, paragraphs: paragraphs)
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

    /// Slide `slide` at build stage `stage` (0: before any build; `stageCount - 1`: all played).
    /// Actions (moves, rotations) are not applied: their drawables stay where the slide puts them.
    public func render(slide: UInt64, stage: Int) -> RenderedSlide {
        render(slide: slide, stage: stage, of: builds(onSlide: slide))
    }

    /// As `render(slide:stage:)`, with the slide's `builds(onSlide:)` already worked out (a host
    /// drawing every stage computes it once).
    public func render(slide: UInt64, stage: Int, of sequence: SlideBuildSequence) -> RenderedSlide {
        guard !sequence.chunks.isEmpty else { return render(slide: slide) }
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
        return render(slide: slide, hiding: (hiddenDrawables, hiddenParagraphs))
    }
}
