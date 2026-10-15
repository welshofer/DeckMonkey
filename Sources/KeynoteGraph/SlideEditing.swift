import Foundation
import IWASchema
import SwiftProtobuf

/// Phase 3a: move and delete slides within a deck (docs/spec.md §9).
///
/// In a Keynote 15.4 file the show's `slideTree.slides` lists the slide nodes in order (each node
/// points at its slide), and every slide lives in its own component, `Index/Slide-<id>.iwa`. In the
/// decks 15.4 alone saved, nothing outside a slide's component holds a strong reference into it but
/// its node: moving a slide reorders the list; deleting one removes the node, the slide's component,
/// its `ComponentInfo` and the references other components keep to it, the objects elsewhere that
/// only the slide kept alive (as Keynote's own save collects them: a table's model and tiles, a
/// chart's non-style archives), components that leaves empty, and any data only the removed
/// objects used (DataInfo, file, data-metadata entry).
///
/// Refused rather than guessed: a tree kept under a root node (Keynote 6.5) or nodes with children
/// (nested slides), deleting the last slide, and deleting a slide whose component something else
/// still references strongly.
extension KeynoteDocument {
    public enum SlideEditFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedTree(String)
        case indexOutOfRange(Int, count: Int)
        case lastSlide
        case referencedFromOutside(slide: UInt64, by: UInt64)

        public var description: String {
            switch self {
            case .unsupportedTree(let why): return "the slide tree is not a flat list (\(why)); Phase 3a edits flat trees"
            case .indexOutOfRange(let i, let n): return "slide index \(i) is out of range (the deck has \(n) slides)"
            case .lastSlide: return "a deck keeps at least one slide"
            case .referencedFromOutside(let slide, let by): return "object \(by) outside slide \(slide)'s component still references it strongly"
            }
        }
    }

    public struct SlideEntry: Equatable, Sendable {
        public var node: UInt64
        public var slide: UInt64
        public var skipped: Bool
        /// The slide's component, e.g. "Index/Slide-2652175.iwa".
        public var component: String
    }

    public struct SlideDeleteReport: Equatable, Sendable {
        public var slide: UInt64
        public var component: String
        public var removedObjects: Int
        public var removedData: [UInt64] = []
        public var removedFiles: [String] = []
    }

    var showIdentifier: UInt64? {
        store.identifiers.first { store.record(for: $0)?.info.messageInfos.first?.type == Self.showType }
    }

    /// The slides in show order. Throws for a tree Phase 3a does not edit.
    public func slideList() throws -> [SlideEntry] {
        guard let showID = showIdentifier, let show = decoded(KN_ShowArchive.self, showID) else {
            throw SlideEditFailure.unsupportedTree("no show")
        }
        if show.slideTree.slides.isEmpty { throw SlideEditFailure.unsupportedTree("a root node, as Keynote 6.5 wrote") }
        return try show.slideTree.slides.map { ref in
            guard let node = decoded(KN_SlideNodeArchive.self, ref.identifier), node.hasSlide else {
                throw SlideEditFailure.unsupportedTree("node \(ref.identifier) has no slide")
            }
            if !node.children.isEmpty { throw SlideEditFailure.unsupportedTree("node \(ref.identifier) has nested slides") }
            guard let component = store.entry(for: node.slide.identifier)?.component else {
                throw SlideEditFailure.unsupportedTree("slide \(node.slide.identifier) is missing")
            }
            return SlideEntry(node: ref.identifier, slide: node.slide.identifier, skipped: node.isSkipped, component: component)
        }
    }

    /// Moves the slide at `from` so that it ends up at `to` (0-based, in show order).
    public mutating func moveSlide(from: Int, to: Int) throws {
        let list = try slideList()
        guard list.indices.contains(from) else { throw SlideEditFailure.indexOutOfRange(from, count: list.count) }
        guard list.indices.contains(to) else { throw SlideEditFailure.indexOutOfRange(to, count: list.count) }
        guard from != to, let showID = showIdentifier, var show = decoded(KN_ShowArchive.self, showID) else { return }
        let node = show.slideTree.slides.remove(at: from)
        show.slideTree.slides.insert(node, at: to)
        try replacePayload(of: showID, with: try show.serializedData(partial: true))
    }

    /// Deletes the slide at `index` (0-based, in show order) with everything only it used.
    @discardableResult
    public mutating func deleteSlide(at index: Int) throws -> SlideDeleteReport {
        let list = try slideList()
        guard list.indices.contains(index) else { throw SlideEditFailure.indexOutOfRange(index, count: list.count) }
        guard list.count > 1 else { throw SlideEditFailure.lastSlide }
        let entry = list[index]
        guard let showID = showIdentifier, var show = decoded(KN_ShowArchive.self, showID), var metadata = packageMetadata else {
            throw SlideEditFailure.unsupportedTree("no show or package metadata")
        }
        let doomedComponent = store.components.first { $0.name == entry.component }?.records ?? []
        let doomed = Set(doomedComponent.map(\.identifier)).union([entry.node])

        // Nothing outside may still hold a strong reference into what goes (headers list the strong ones).
        for component in store.components where component.name != entry.component {
            for record in component.records where !doomed.contains(record.identifier) && record.identifier != showID {
                for info in record.info.messageInfos where info.objectReferences.contains(where: doomed.contains) {
                    throw SlideEditFailure.referencedFromOutside(slide: entry.slide, by: record.identifier)
                }
            }
        }

        // What only the slide kept alive goes with it, as Keynote's own save would collect it: an
        // object outside the component whose every strong referrer is going (a table's model and
        // tiles, a chart's non-style archives, their captions). Strong references are the header
        // lists (invariant 4); the document and package metadata are roots.
        var referrers = [UInt64: Set<UInt64>]()
        for component in store.components {
            for record in component.records {
                for info in record.info.messageInfos {
                    for target in info.objectReferences { referrers[target, default: []].insert(record.identifier) }
                }
            }
        }
        var gone = doomed
        var frontier = Array(doomed)
        while let next = frontier.popLast() {
            guard let record = store.record(for: next) else { continue }
            for target in record.info.messageInfos.flatMap(\.objectReferences)
            where !gone.contains(target) && target > 2 && target != showID && store.entry(for: target) != nil {
                if let from = referrers[target], from.isSubset(of: gone) {
                    gone.insert(target)
                    frontier.append(target)
                }
            }
        }
        // The calculation engine tracks each formula owner (a table, a chart) through a dependency
        // record that names its owner; Keynote drops the records of owners that are gone. Drop them
        // from the tracker's list, then collect them and what only they kept alive (their tiles).
        // Known limit: after deleting a table, Keynote's next save also rebuilds a few dependency
        // records of the tables that remain (tables.key: 17 of ours become 14 of its own); the deck
        // opens clean and renders identically, and that cache is Keynote's to maintain.
        let calcEngineType: UInt32 = 4000, ownerDependenciesType: UInt32 = 4008
        if let engineID = store.identifiers.first(where: { store.record(for: $0)?.info.messageInfos.first?.type == calcEngineType }),
           !gone.contains(engineID), var engine = decoded(TSCE_CalculationEngineArchive.self, engineID) {
            // Owners are named by reference or by UUID (a table registers several owners, each with
            // a UUID inside the table's archives): collect the UUIDs the removed objects carry.
            var goneUUIDs = Set<ReferenceRewriter.UUIDValue>()
            for id in gone {
                guard let record = store.record(for: id) else { continue }
                for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil {
                    if let d = try? ReferenceDerivation.derive(type: info.type, payload: record.payloads[i]) { goneUUIDs.formUnion(d.uuids) }
                }
            }
            let orphaned = engine.dependencyTracker.formulaOwnerDependencies.map(\.identifier).filter { id in
                guard store.record(for: id)?.info.messageInfos.first?.type == ownerDependenciesType,
                      let deps = decoded(TSCE_FormulaOwnerDependenciesArchive.self, id) else { return false }
                if deps.hasFormulaOwner && gone.contains(deps.formulaOwner.identifier) { return true }
                let owner = ReferenceRewriter.UUIDValue(lower: deps.formulaOwnerUid.lower, upper: deps.formulaOwnerUid.upper)
                if goneUUIDs.contains(owner) { return true }
                // Sub-owners (filters, summaries, categories) name the table as their base owner.
                return deps.hasBaseOwnerUid && goneUUIDs.contains(.init(lower: deps.baseOwnerUid.lower, upper: deps.baseOwnerUid.upper))
            }
            if !orphaned.isEmpty {
                engine.dependencyTracker.formulaOwnerDependencies.removeAll { orphaned.contains($0.identifier) }
                try replacePayload(of: engineID, with: try engine.serializedData(partial: true))
                referrers = [:]
                for component in store.components {
                    for record in component.records {
                        for info in record.info.messageInfos {
                            for target in info.objectReferences { referrers[target, default: []].insert(record.identifier) }
                        }
                    }
                }
                for id in orphaned where referrers[id, default: []].isSubset(of: gone) {
                    gone.insert(id)
                    frontier.append(id)
                }
                while let next = frontier.popLast() {
                    guard let record = store.record(for: next) else { continue }
                    for target in record.info.messageInfos.flatMap(\.objectReferences)
                    where !gone.contains(target) && target > 2 && target != showID && store.entry(for: target) != nil {
                        if let from = referrers[target], from.isSubset(of: gone) {
                            gone.insert(target)
                            frontier.append(target)
                        }
                    }
                }
            }
        }
        let collected = gone.subtracting(doomed)

        // Data the removed objects used: candidates for removal once they are gone.
        var candidates = [UInt64]()
        for component in store.components {
            for record in component.records where gone.contains(record.identifier) {
                for info in record.info.messageInfos { candidates += info.dataReferences }
            }
        }

        show.slideTree.slides.removeAll { $0.identifier == entry.node }
        try replacePayload(of: showID, with: try show.serializedData(partial: true))
        store.removeRecords([entry.node])
        store.removeComponent(entry.component)
        package.remove(entry.component)
        store.removeRecords(collected)
        // Components the collection emptied go too.
        let emptied = store.components.filter { $0.records.isEmpty }.map(\.name)
        for name in emptied {
            store.removeComponent(name)
            package.remove(name)
        }

        // The component's ComponentInfo, other components' references to it, and data-index
        // entries for objects that no longer exist.
        let locators = Set(([entry.component] + emptied).map { String($0.dropFirst("Index/".count).dropLast(".iwa".count)) })
        let removedComponentIDs = Set(metadata.components.filter { locators.contains($0.locator.isEmpty ? $0.preferredLocator : $0.locator) }.map(\.identifier))
        metadata.components.removeAll { removedComponentIDs.contains($0.identifier) }
        for c in metadata.components.indices {
            metadata.components[c].externalReferences.removeAll {
                removedComponentIDs.contains($0.componentIdentifier) || ($0.hasObjectIdentifier && gone.contains($0.objectIdentifier))
            }
            metadata.components[c].objectUuidMapEntries.removeAll { gone.contains($0.identifier) }
            for d in metadata.components[c].dataReferences.indices {
                metadata.components[c].dataReferences[d].objectReferenceList.removeAll { gone.contains($0.objectIdentifier) }
            }
            metadata.components[c].dataReferences.removeAll { $0.objectReferenceList.isEmpty }
        }
        let removed = try commitData([], replacing: candidates, metadata: &metadata)
        return SlideDeleteReport(slide: entry.slide, component: entry.component, removedObjects: gone.count,
                                 removedData: removed.data, removedFiles: removed.files)
    }
}
