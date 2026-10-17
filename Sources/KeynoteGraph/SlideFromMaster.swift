import Foundation
import IWAArchive
import IWAContainer
import IWASchema
import SwiftProtobuf

/// A new slide on one of the deck's masters, as Keynote's New Slide makes it: the master's title,
/// body and slide-number placeholders and the objects it tags for its slides (sage tags: "Media",
/// "Text") are copied with fresh identifiers and UUIDs, their text emptied; the master's guides
/// come too. A slide's notes and its node have no counterpart on a master, so they are copied from
/// a donor slide of this deck (one on the same master when there is one) and emptied: nothing is
/// made from nothing. The master's own objects, its object placeholder and its stylesheet record
/// stay on the master.
extension KeynoteDocument {
    public struct NewSlideReport: Equatable, Sendable {
        public var slide: UInt64
        public var node: UInt64
        public var component: String
    }

    public enum NewSlideFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case notAMaster(UInt64)
        case noDonorSlide
        case masterHasBuilds(UInt64)

        public var description: String {
            switch self {
            case .notAMaster(let id): return "\(id) is not one of this deck's masters"
            case .noDonorSlide: return "the deck has no slide to take a node and notes from"
            case .masterHasBuilds(let id): return "master \(id) has builds; new slides copy masters without builds"
            }
        }
    }

    /// The deck's masters in the theme's order: identifier and name.
    public func masters() -> [(id: UInt64, name: String)] {
        var out = [(UInt64, String)]()
        for id in store.identifiers where store.record(for: id)?.info.messageInfos.first?.type == Self.slideType {
            guard let s = decoded(KN_SlideArchive.self, id), s.hasName, store.entry(for: id)?.component.contains("TemplateSlide") == true else { continue }
            out.append((id, s.name))
        }
        if let showID = showIdentifier, let show = decoded(KN_ShowArchive.self, showID), show.hasTheme,
           let theme = decoded(KN_ThemeArchive.self, show.theme.identifier) {
            let order = theme.templates.map(\.identifier)
            out.sort { (order.firstIndex(of: $0.0) ?? .max, $0.0) < (order.firstIndex(of: $1.0) ?? .max, $1.0) }
        }
        return out.map { (id: $0.0, name: $0.1) }
    }

    @discardableResult
    public mutating func addSlide(fromMaster masterID: UInt64, at position: Int? = nil) throws -> NewSlideReport {
        let list = try slideList()
        let insertAt = position ?? list.count
        guard (0...list.count).contains(insertAt) else { throw SlideEditFailure.indexOutOfRange(insertAt, count: list.count) }
        guard masters().contains(where: { $0.id == masterID }), let master = decoded(KN_SlideArchive.self, masterID),
              store.entry(for: masterID) != nil else { throw NewSlideFailure.notAMaster(masterID) }
        guard master.builds.isEmpty, master.buildChunks.isEmpty else { throw NewSlideFailure.masterHasBuilds(masterID) }
        guard let showID = showIdentifier, var show = decoded(KN_ShowArchive.self, showID), var metadata = packageMetadata else {
            throw SlideEditFailure.unsupportedTree("no show or package metadata")
        }
        // The donor: a slide on the same master if any, else the first slide.
        guard let donor = list.first(where: { decoded(KN_SlideArchive.self, $0.slide)?.templateSlide.identifier == masterID }) ?? list.first,
              let donorSlide = decoded(KN_SlideArchive.self, donor.slide),
              let nodeRecord = store.record(for: donor.node), let nodeComponent = store.entry(for: donor.node)?.component else {
            throw NewSlideFailure.noDonorSlide
        }

        // What the master gives its slides.
        var drawables = [UInt64]()
        for ref in [master.hasTitlePlaceholder ? master.titlePlaceholder.identifier : nil,
                    master.hasBodyPlaceholder ? master.bodyPlaceholder.identifier : nil,
                    master.hasSlideNumberPlaceholder ? master.slideNumberPlaceholder.identifier : nil].compactMap({ $0 }) {
            drawables.append(ref)
        }
        let tagged = master.sageTagToInfoMap.map(\.info.identifier)
        drawables += tagged.filter { !drawables.contains($0) }
        let referrers = referrerIndex()
        var roots = Set(drawables)
        if master.hasUserDefinedGuideStorage { roots.insert(master.userDefinedGuideStorage.identifier) }
        let copied = heldOnly(by: roots, referrers: referrers, keeping: [masterID, showID])
        let note = donorSlide.hasNote ? donorSlide.note.identifier : nil
        let noteCopied = note.map { heldOnly(by: [$0], referrers: referrers, keeping: [donor.slide, showID]) } ?? []

        var allocator = IDAllocator(seed: max(store.highestIdentifier, metadata.lastObjectIdentifier) + 1)
        var identifiers = [UInt64: UInt64]()
        let newSlide = allocator.allocate(), newNode = allocator.allocate()
        identifiers[masterID] = newSlide
        identifiers[donor.node] = newNode
        for id in copied.union(noteCopied).sorted() { identifiers[id] = allocator.allocate() }

        // Fresh UUIDs for every copied object that has one, in the new component's map.
        func locatorOf(_ c: TSP_ComponentInfo) -> String { c.locator.isEmpty ? c.preferredLocator : c.locator }
        var generator = SystemRandomNumberGenerator()
        var uuids = [ReferenceRewriter.UUIDValue: ReferenceRewriter.UUIDValue]()
        var newEntries = [TSP_ObjectUUIDMapEntry]()
        var masterUUID: TSP_UUID?
        for c in metadata.components {
            for e in c.objectUuidMapEntries {
                if e.identifier == masterID { masterUUID = e.uuid }
                guard let new = identifiers[e.identifier], e.identifier != masterID, e.identifier != donor.node else { continue }
                let fresh = ReferenceRewriter.UUIDValue(lower: generator.next(), upper: generator.next())
                uuids[.init(lower: e.uuid.lower, upper: e.uuid.upper)] = fresh
                newEntries.append(TSP_ObjectUUIDMapEntry.with { $0.identifier = new; $0.uuid = TSP_UUID.with { $0.lower = fresh.lower; $0.upper = fresh.upper } })
            }
        }
        // The slide itself has a UUID of its own, as every slide Keynote makes does.
        newEntries.append(TSP_ObjectUUIDMapEntry.with {
            $0.identifier = newSlide
            $0.uuid = TSP_UUID.with { $0.lower = generator.next(); $0.upper = generator.next() }
        })
        let rewriter = ReferenceRewriter(index: try FieldIndex.load(version: TypeRegistry.pinnedVersion), identifiers: identifiers, uuids: uuids)
        func copy(_ record: ArchiveRecord, as id: UInt64? = nil) throws -> ArchiveRecord {
            var info = record.info
            info.setIdentifier(id ?? identifiers[record.identifier]!)
            var payloads = record.payloads
            for (i, m) in info.messageInfos.enumerated() where i < payloads.count {
                if m.baseMessageIndex == nil, let type = Schema.messageType(for: m.type) {
                    payloads[i] = try rewriter.rewrite(payloads[i], message: type.protoMessageName)
                }
                info.messageInfos[i] = try Self.remapped(m, identifiers: identifiers, length: UInt32(payloads[i].count))
            }
            return ArchiveRecord(info: info, payloads: payloads, isDirty: true)
        }

        // The slide record: the master's, less what only a master has, pointing at its master.
        guard let masterRecord = store.record(for: masterID) else { throw NewSlideFailure.notAMaster(masterID) }
        var records = [try copy(masterRecord, as: newSlide)]
        for id in copied.union(noteCopied).sorted() {
            guard let record = store.record(for: id) else { continue }
            records.append(try copy(record))
        }
        let newLocator = "Slide-\(newSlide)"
        let newComponent = "Index/\(newLocator).iwa"
        guard IWAPackage.isSafeEntryName(newComponent) else { throw SlideCloneFailure.unsafeLocator(newLocator) }
        store.addComponent(newComponent, records: records)

        var slide = master
        let keep = Set(drawables)
        slide.ownedDrawables = master.ownedDrawables.filter { keep.contains($0.identifier) }.map { ref in TSP_Reference.with { $0.identifier = identifiers[ref.identifier]! } }
        slide.drawablesZOrder = master.drawablesZOrder.filter { keep.contains($0.identifier) }.map { ref in TSP_Reference.with { $0.identifier = identifiers[ref.identifier]! } }
        slide.sageTagToInfoMap = master.sageTagToInfoMap.compactMap { e in
            guard let new = identifiers[e.info.identifier] else { return nil }
            var entry = e
            entry.info = TSP_Reference.with { $0.identifier = new }
            return entry
        }
        if master.hasTitlePlaceholder { slide.titlePlaceholder.identifier = identifiers[master.titlePlaceholder.identifier]! }
        if master.hasBodyPlaceholder { slide.bodyPlaceholder.identifier = identifiers[master.bodyPlaceholder.identifier]! }
        if master.hasSlideNumberPlaceholder { slide.slideNumberPlaceholder.identifier = identifiers[master.slideNumberPlaceholder.identifier]! }
        if master.hasUserDefinedGuideStorage, let g = identifiers[master.userDefinedGuideStorage.identifier] { slide.userDefinedGuideStorage.identifier = g }
        slide.clearObjectPlaceholder()
        slide.clearName()
        slide.clearClassicStylesheetRecord()
        slide.bodyParagraphStyles = []
        slide.bodyListStyles = []
        slide.clearThumbnailTextForTitlePlaceholder()
        slide.clearThumbnailTextForBodyPlaceholder()
        slide.clearSlideObjectsLayerWithTemplate()
        slide.infosUsingObjectPlaceholderGeometry = []
        slide.clearInfoUsingObjectPlaceholderGeometry()
        slide.clearInfoUsingObjectPlaceholderGeometryMatchesObjectPlaceholderGeometry()
        slide.templateSlide = TSP_Reference.with { $0.identifier = masterID }
        slide.inDocument = true
        if let note, let new = identifiers[note] { slide.note = TSP_Reference.with { $0.identifier = new } } else { slide.clearNote() }
        try replacePayload(of: newSlide, with: try slide.serializedData(partial: true))

        // (The copies' parent references already name the new slide: the master's identifier maps
        // to it in the rewrite.)

        // Placeholders and notes start empty, as on Keynote's new slide; the objects a master tags
        // keep their words (Kyoto's Quote master gives "Type a quote here." and its attribution).
        var emptied = [UInt64]()
        for placeholder in [master.titlePlaceholder, master.bodyPlaceholder, master.slideNumberPlaceholder] where placeholder.identifier != 0 {
            guard let new = identifiers[placeholder.identifier], let p = decoded(KN_PlaceholderArchive.self, new), p.super.hasOwnedStorage else { continue }
            emptied.append(p.super.ownedStorage.identifier)
        }
        if let note = slide.hasNote ? slide.note.identifier : nil, let n = decoded(KN_NoteArchive.self, note), n.hasContainedStorage {
            emptied.append(n.containedStorage.identifier)
        }
        for storage in emptied {
            guard let text = storageText(storage), !text.isEmpty else { continue }
            _ = try setParagraphs(in: storage, [TextParagraphs.Paragraph("")])
        }

        // The node: the donor's, on the new slide, a top-level slide that shows.
        var node = try KN_SlideNodeArchive(serializedBytes: nodeRecord.payloads[0], extensions: Schema.extensions, partial: true)
        node.slide = TSP_Reference.with { $0.identifier = newSlide }
        node.children = []
        node.isSkipped = false
        node.hasNote_p = false
        node.thumbnailsAreDirty = true
        if let masterUUID { node.templateSlideID = masterUUID }
        var newNodeRecord = try copy(nodeRecord, as: newNode)
        newNodeRecord.payloads[0] = try node.serializedData(partial: true)
        store.append(newNodeRecord, to: nodeComponent)
        try replacePayload(of: newNode, with: try node.serializedData(partial: true))

        show.slideTree.slides.insert(TSP_Reference.with { $0.identifier = newNode }, at: insertAt)
        try replacePayload(of: showID, with: try show.serializedData(partial: true))

        // The component's metadata: a slide component's, as the donor's is, with the new UUIDs;
        // data and external references are derived at save.
        metadata = packageMetadata ?? metadata
        let donorLocator = String(donor.component.dropFirst("Index/".count).dropLast(".iwa".count))
        guard var info = metadata.components.first(where: { locatorOf($0) == donorLocator }) else {
            throw SlideCloneFailure.noComponentInfo(donor.component)
        }
        info.identifier = newSlide
        info.locator = newLocator
        info.objectUuidMapEntries = newEntries
        info.dataReferences = []
        info.externalReferences = []
        metadata.components.append(info)
        // A node gets a UUID where the donor's node has one.
        let nodeLocator = String(nodeComponent.dropFirst("Index/".count).dropLast(".iwa".count))
        if let d = metadata.components.firstIndex(where: { locatorOf($0) == nodeLocator }),
           metadata.components[d].objectUuidMapEntries.contains(where: { $0.identifier == donor.node }) {
            metadata.components[d].objectUuidMapEntries.append(TSP_ObjectUUIDMapEntry.with {
                $0.identifier = newNode
                $0.uuid = TSP_UUID.with { $0.lower = generator.next(); $0.upper = generator.next() }
            })
        }
        metadata.lastObjectIdentifier = max(metadata.lastObjectIdentifier, allocator.highWaterMark)
        try replacePayload(of: 2, with: try metadata.serializedData(partial: true))
        return NewSlideReport(slide: newSlide, node: newNode, component: newComponent)
    }
}
