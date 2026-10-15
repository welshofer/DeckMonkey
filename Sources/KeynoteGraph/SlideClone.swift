import Foundation
import IWAArchive
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
/// source's, with the copies' identifiers), the Document component an external reference to it,
/// and the new node is inserted after the source in the show.
///
/// Refused rather than guessed: slides holding tables, charts or builds (they register owners and
/// targets by UUID with the calculation engine and the build system), and trees Phase 3a does not
/// edit.
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

        public var description: String {
            switch self {
            case .unsupportedContent(let slide, let type): return "slide \(slide) holds \(type); Phase 3a clones slides without tables, charts or builds"
            case .noComponentInfo(let name): return "no ComponentInfo for \(name)"
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
        for record in source.records {
            for info in record.info.messageInfos where info.baseMessageIndex == nil {
                let name = registry?.name(for: info.type) ?? ""
                if name.hasPrefix("TST.") || name.hasPrefix("TSCH.") || name.hasPrefix("TSCE.") || name.contains("Build") {
                    throw SlideCloneFailure.unsupportedContent(slide: entry.slide, type: name)
                }
            }
        }
        let locator = String(entry.component.dropFirst("Index/".count).dropLast(".iwa".count))
        guard let sourceInfo = metadata.components.first(where: { ($0.locator.isEmpty ? $0.preferredLocator : $0.locator) == locator }) else {
            throw SlideCloneFailure.noComponentInfo(entry.component)
        }

        // Fresh identifiers for every copied object (invariant 3) and fresh UUIDs for their map.
        var allocator = IDAllocator(seed: max(store.highestIdentifier, metadata.lastObjectIdentifier) + 1)
        var identifiers = [UInt64: UInt64]()
        for record in source.records { identifiers[record.identifier] = allocator.allocate() }
        identifiers[entry.node] = allocator.allocate()
        var generator = SystemRandomNumberGenerator()
        var uuids = [ReferenceRewriter.UUIDValue: ReferenceRewriter.UUIDValue]()
        var newUUIDEntries = [TSP_ObjectUUIDMapEntry]()
        for e in sourceInfo.objectUuidMapEntries {
            guard let new = identifiers[e.identifier] else { continue }
            let fresh = ReferenceRewriter.UUIDValue(lower: generator.next(), upper: generator.next())
            uuids[.init(lower: e.uuid.lower, upper: e.uuid.upper)] = fresh
            newUUIDEntries.append(TSP_ObjectUUIDMapEntry.with { $0.identifier = new; $0.uuid = TSP_UUID.with { $0.lower = fresh.lower; $0.upper = fresh.upper } })
        }
        let rewriter = ReferenceRewriter(index: try FieldIndex.load(version: TypeRegistry.pinnedVersion), identifiers: identifiers, uuids: uuids)

        func copy(_ record: ArchiveRecord) throws -> ArchiveRecord {
            var info = record.info
            info.setIdentifier(identifiers[record.identifier]!)
            var payloads = record.payloads
            for (i, m) in info.messageInfos.enumerated() where i < payloads.count {
                if m.baseMessageIndex == nil, let type = Schema.messageType(for: m.type) {
                    payloads[i] = try rewriter.rewrite(payloads[i], message: type.protoMessageName)
                }
                info.messageInfos[i] = try Self.remapped(m, identifiers: identifiers, length: UInt32(payloads[i].count))
            }
            return ArchiveRecord(info: info, payloads: payloads, isDirty: true)
        }

        let newSlide = identifiers[entry.slide]!, newNode = identifiers[entry.node]!
        let newLocator = "Slide-\(newSlide)"
        let newComponent = "Index/\(newLocator).iwa"
        store.addComponent(newComponent, records: try source.records.map(copy))
        store.append(try copy(nodeRecord), to: nodeComponent)

        show.slideTree.slides.insert(TSP_Reference.with { $0.identifier = newNode }, at: insertAt)
        try replacePayload(of: showID, with: try show.serializedData(partial: true))
        metadata = packageMetadata ?? metadata

        // The new component's ComponentInfo (its external references, and the Document
        // component's reference to it, are re-derived at save).
        var info = sourceInfo
        info.identifier = newSlide
        info.locator = newLocator
        info.objectUuidMapEntries = newUUIDEntries
        for d in info.dataReferences.indices {
            for o in info.dataReferences[d].objectReferenceList.indices {
                let old = info.dataReferences[d].objectReferenceList[o].objectIdentifier
                info.dataReferences[d].objectReferenceList[o].objectIdentifier = identifiers[old] ?? old
            }
        }
        metadata.components.append(info)
        let nodeLocator = String(nodeComponent.dropFirst("Index/".count).dropLast(".iwa".count))
        if let d = metadata.components.firstIndex(where: { ($0.locator.isEmpty ? $0.preferredLocator : $0.locator) == nodeLocator }) {
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
    static func remapped(_ info: MessageInfo, identifiers: [UInt64: UInt64], length: UInt32) throws -> MessageInfo {
        var fields = info.fields
        for i in fields.indices where fields[i].number == MessageInfo.fieldInfosField {
            guard case .lengthDelimited(let bytes) = fields[i].value,
                  var fieldInfo = try? TSP_FieldInfo(serializedBytes: bytes, partial: true),
                  fieldInfo.objectReferences.contains(where: { identifiers[$0] != nil }) else { continue }
            fieldInfo.objectReferences = fieldInfo.objectReferences.map { identifiers[$0] ?? $0 }
            fields[i] = WireField(number: fields[i].number, value: .lengthDelimited(try fieldInfo.serializedData(partial: true)))
        }
        var out = try MessageInfo(fields: fields)
        out.setLength(length)
        if out.objectReferences.contains(where: { identifiers[$0] != nil }) {
            out.setObjectReferences(out.objectReferences.map { identifiers[$0] ?? $0 })
        }
        return out
    }
}
