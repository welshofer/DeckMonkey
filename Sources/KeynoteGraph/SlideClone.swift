import Foundation
import IWAArchive
import IWAContainer
import IWASchema
import SwiftProtobuf

/// Phase 3a: duplicate a slide within its deck (docs/spec.md §9, AT-20).
///
/// Everything in the slide's component, and its node, is copied with fresh identifiers from the
/// document's allocator (invariant 3: seeded above `last_object_identifier` and every identifier in
/// use, written back). References are rewritten by the schema-driven `ReferenceRewriter`:
/// references between copied objects follow the copies, references to everything else (masters,
/// template slides, the stylesheet, the theme, data) stay shared. Each copied object gets a fresh
/// UUID in the new component's UUID map, and a `TSP.UUID` inside a copied payload that named a
/// copied object is rewritten to match. The new component gets its own `ComponentInfo` (the
/// source's, with the copies' identifiers; external references are re-derived at save), and the
/// new node is inserted after the source in the show.
///
/// Tables come along whole: everything outside the slide that only it keeps alive (the table's
/// info, model, tiles, data lists and header buckets) is copied too, each object alone in its
/// component into a new one named as Keynote's duplicate names it. Each copied table gets a fresh
/// `table_id`; its formula-owner family (the table_id UUID plus per-kind offsets) moves with it in
/// every `TSP.UUID` and `TSP.CFUUIDArchive`, and is registered with the calculation engine as
/// Keynote registers a duplicate: owner-ID map twins under fresh internal identifiers, copies of
/// the family's dependency records and tiles with those identifiers, and its UUID-map entries.
///
/// Charts are copied like any drawable: Keynote's own duplicate of a chart slide registers
/// nothing with the calculation engine (charts.key), and neither does this.
///
/// Refused rather than guessed: slides holding builds (they name their targets to the build
/// system in ways not yet learned), and trees Phase 3a does not edit.
extension KeynoteDocument {
    public struct SlideCloneReport: Equatable, Sendable {
        public var source: UInt64
        public var slide: UInt64
        public var node: UInt64
        public var component: String
        public var copiedObjects: Int
    }

    public enum SlideCloneFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedContent(slide: UInt64, type: String)
        case noComponentInfo(String)
        /// A locator from the source deck that is not a safe component name (a hostile file).
        case unsafeLocator(String)
        /// The calculation engine's internal owner identifiers are exhausted (uint32).
        case ownerIdentifiersExhausted

        public var description: String {
            switch self {
            case .unsupportedContent(let slide, let type): return "slide \(slide) holds \(type); Phase 3a clones slides without builds"
            case .noComponentInfo(let name): return "no ComponentInfo for \(name)"
            case .unsafeLocator(let locator): return "the source deck names a component \"\(locator)\", which is not a safe name"
            case .ownerIdentifiersExhausted: return "the calculation engine has no internal owner identifiers left"
            }
        }
    }

    @discardableResult
    public mutating func cloneSlide(at index: Int, to position: Int? = nil) throws -> SlideCloneReport {
        let list = try slideList()
        guard list.indices.contains(index) else { throw SlideEditFailure.indexOutOfRange(index, count: list.count) }
        let insertAt = position ?? index + 1
        guard (0...list.count).contains(insertAt) else { throw SlideEditFailure.indexOutOfRange(insertAt, count: list.count) }
        let entry = list[index]
        guard let showID = showIdentifier, var show = decoded(KN_ShowArchive.self, showID), var metadata = packageMetadata,
              let source = store.components.first(where: { $0.name == entry.component }),
              let nodeRecord = store.record(for: entry.node), let nodeComponent = store.entry(for: entry.node)?.component else {
            throw SlideEditFailure.unsupportedTree("no show, package metadata or slide records")
        }
        // What is copied: the slide's component, its node, and every object outside them that only
        // they keep alive (a table's info, model, tiles, data lists and header buckets).
        let roots = Set(source.records.map(\.identifier)).union([entry.node])
        let copied = heldOnly(by: roots, referrers: referrerIndex(), keeping: [showID])
        for id in copied {
            guard let record = store.record(for: id) else { continue }
            for info in record.info.messageInfos where info.baseMessageIndex == nil {
                let name = registry?.name(for: info.type) ?? ""
                if (name.hasPrefix("TSCE.") && name != "TSCE.TrackedReferenceStoreArchive") || name.contains("Build") {
                    throw SlideCloneFailure.unsupportedContent(slide: entry.slide, type: name)
                }
            }
        }
        let locator = String(entry.component.dropFirst("Index/".count).dropLast(".iwa".count))
        func locatorOf(_ c: TSP_ComponentInfo) -> String { c.locator.isEmpty ? c.preferredLocator : c.locator }
        guard let sourceInfo = metadata.components.first(where: { locatorOf($0) == locator }) else {
            throw SlideCloneFailure.noComponentInfo(entry.component)
        }

        // Fresh identifiers for every copied object (invariant 3), fresh UUIDs for the UUID maps,
        // and a fresh table_id for every copied table, its formula-owner family moving with it.
        var allocator = IDAllocator(seed: max(store.highestIdentifier, metadata.lastObjectIdentifier) + 1)
        var identifiers = [UInt64: UInt64]()
        for record in source.records { identifiers[record.identifier] = allocator.allocate() }
        identifiers[entry.node] = allocator.allocate()
        for id in copied.sorted() where identifiers[id] == nil { identifiers[id] = allocator.allocate() }
        var generator = SystemRandomNumberGenerator()
        var uuids = [ReferenceRewriter.UUIDValue: ReferenceRewriter.UUIDValue]()
        var newUUIDEntries = [String: [TSP_ObjectUUIDMapEntry]]()        // component locator → entries
        for c in metadata.components {
            for e in c.objectUuidMapEntries {
                guard let new = identifiers[e.identifier], e.identifier != entry.node else { continue }
                let fresh = ReferenceRewriter.UUIDValue(lower: generator.next(), upper: generator.next())
                uuids[.init(lower: e.uuid.lower, upper: e.uuid.upper)] = fresh
                newUUIDEntries[locatorOf(c), default: []].append(TSP_ObjectUUIDMapEntry.with {
                    $0.identifier = new
                    $0.uuid = TSP_UUID.with { $0.lower = fresh.lower; $0.upper = fresh.upper }
                })
            }
        }
        // The copied tables, registered with the calculation engine (TableRegistration).
        let tables = try TableRegistration.plan(source: self, target: self, copied: copied, keeping: [showID], strict: false,
                                                identifiers: &identifiers, allocator: &allocator)
        let rewriter = ReferenceRewriter(index: try FieldIndex.load(version: TypeRegistry.pinnedVersion), identifiers: identifiers, uuids: uuids,
                                         families: tables.families, ownerIDs: tables.ownerIDs)

        func copy(_ record: ArchiveRecord) throws -> ArchiveRecord {
            var info = record.info
            info.setIdentifier(identifiers[record.identifier]!)
            var payloads = record.payloads
            for (i, m) in info.messageInfos.enumerated() where i < payloads.count {
                if m.baseMessageIndex == nil, let type = Schema.messageType(for: m.type) {
                    payloads[i] = try rewriter.rewrite(payloads[i], message: type.protoMessageName)
                    if i == 0 { payloads[i] = try tables.withTableID(payloads[i], record: record.identifier) }
                }
                info.messageInfos[i] = try Self.remapped(m, identifiers: identifiers, length: UInt32(payloads[i].count))
            }
            return ArchiveRecord(info: info, payloads: payloads, isDirty: true)
        }
        func remappedDataReferences(_ info: inout TSP_ComponentInfo) {
            for d in info.dataReferences.indices {
                for o in info.dataReferences[d].objectReferenceList.indices {
                    let old = info.dataReferences[d].objectReferenceList[o].objectIdentifier
                    info.dataReferences[d].objectReferenceList[o].objectIdentifier = identifiers[old] ?? old
                }
            }
        }

        let newSlide = identifiers[entry.slide]!, newNode = identifiers[entry.node]!
        let newLocator = "Slide-\(newSlide)"
        let newComponent = "Index/\(newLocator).iwa"
        store.addComponent(newComponent, records: try source.records.map(copy))
        store.append(try copy(nodeRecord), to: nodeComponent)
        // Objects outside the slide: one alone in its component (a table's tile, data list or
        // header bucket) gets a component of its own, `<preferred locator>-<new id>`, as Keynote's
        // duplicate names them; one in a shared component (the calculation engine's) joins it.
        var newInfos = [TSP_ComponentInfo]()
        for id in copied.subtracting(roots).sorted() {
            guard let record = store.record(for: id), let home = store.entry(for: id)?.component,
                  let records = store.records(in: home) else { continue }
            let homeLocator = String(home.dropFirst("Index/".count).dropLast(".iwa".count))
            if records.count == 1, let homeInfo = metadata.components.first(where: { locatorOf($0) == homeLocator }) {
                var info = homeInfo
                info.identifier = identifiers[id]!
                info.locator = "\(homeInfo.preferredLocator.isEmpty ? homeLocator : homeInfo.preferredLocator)-\(identifiers[id]!)"
                guard IWAPackage.isSafeEntryName("Index/\(info.locator).iwa") else { throw SlideCloneFailure.unsafeLocator(info.locator) }
                info.objectUuidMapEntries = newUUIDEntries[homeLocator] ?? []
                info.externalReferences = []
                remappedDataReferences(&info)
                store.addComponent("Index/\(info.locator).iwa", records: [try copy(record)])
                newInfos.append(info)
            } else {
                store.append(try copy(record), to: home)
            }
        }

        let snapshot = self
        try tables.apply(to: &self, source: snapshot, rewriter: rewriter, identifiers: identifiers, copy: copy)

        show.slideTree.slides.insert(TSP_Reference.with { $0.identifier = newNode }, at: insertAt)
        try replacePayload(of: showID, with: try show.serializedData(partial: true))
        metadata = packageMetadata ?? metadata

        // The new component's ComponentInfo (external references are re-derived at save); copies
        // that joined a shared component get UUID-map entries there.
        var info = sourceInfo
        info.identifier = newSlide
        info.locator = newLocator
        info.objectUuidMapEntries = newUUIDEntries[locator] ?? []
        remappedDataReferences(&info)
        metadata.components.append(info)
        metadata.components += newInfos
        let separate = Set(newInfos.map(\.identifier))
        for c in metadata.components.indices where locatorOf(metadata.components[c]) != locator {
            let added = (newUUIDEntries[locatorOf(metadata.components[c])] ?? []).filter { !separate.contains($0.identifier) }
            if !added.isEmpty, !newInfos.contains(where: { $0.identifier == metadata.components[c].identifier }) {
                metadata.components[c].objectUuidMapEntries += added
            }
        }
        let nodeLocator = String(nodeComponent.dropFirst("Index/".count).dropLast(".iwa".count))
        if let d = metadata.components.firstIndex(where: { locatorOf($0) == nodeLocator }) {
            if metadata.components[d].objectUuidMapEntries.contains(where: { $0.identifier == entry.node }) {
                metadata.components[d].objectUuidMapEntries.append(TSP_ObjectUUIDMapEntry.with {
                    $0.identifier = newNode
                    $0.uuid = TSP_UUID.with { $0.lower = generator.next(); $0.upper = generator.next() }
                })
            }
        }
        metadata.lastObjectIdentifier = max(metadata.lastObjectIdentifier, allocator.highWaterMark)
        try replacePayload(of: 2, with: try metadata.serializedData(partial: true))
        return SlideCloneReport(source: entry.slide, slide: newSlide, node: newNode, component: newComponent, copiedObjects: identifiers.count)
    }

    /// A MessageInfo for a copied payload: identifiers remapped in the reference list and in each
    /// field info's references, the new length; everything else as it was.
    static func remapped(_ info: MessageInfo, identifiers: [UInt64: UInt64], dataIdentifiers: [UInt64: UInt64] = [:], length: UInt32) throws -> MessageInfo {
        var fields = info.fields
        for i in fields.indices where fields[i].number == MessageInfo.fieldInfosField {
            guard case .lengthDelimited(let bytes) = fields[i].value,
                  var fieldInfo = try? TSP_FieldInfo(serializedBytes: bytes, partial: true),
                  fieldInfo.objectReferences.contains(where: { identifiers[$0] != nil })
                    || fieldInfo.dataReferences.contains(where: { dataIdentifiers[$0] != nil }) else { continue }
            fieldInfo.objectReferences = fieldInfo.objectReferences.map { identifiers[$0] ?? $0 }
            fieldInfo.dataReferences = fieldInfo.dataReferences.map { dataIdentifiers[$0] ?? $0 }
            fields[i] = WireField(number: fields[i].number, value: .lengthDelimited(try fieldInfo.serializedData(partial: true)))
        }
        var out = try MessageInfo(fields: fields)
        out.setLength(length)
        if out.objectReferences.contains(where: { identifiers[$0] != nil }) {
            out.setObjectReferences(out.objectReferences.map { identifiers[$0] ?? $0 })
        }
        if out.dataReferences.contains(where: { dataIdentifiers[$0] != nil }) {
            out.setDataReferences(out.dataReferences.map { dataIdentifiers[$0] ?? $0 })
        }
        return out
    }
}
