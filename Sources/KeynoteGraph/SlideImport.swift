import Foundation
import IWAArchive
import IWAContainer
import IWASchema
import SwiftProtobuf

/// Phase 3b: copy a slide from another deck (docs/spec.md §9, §12).
///
/// What is copied is what clone copies: the slide's component, its node, and every object only they
/// keep alive, under fresh identifiers from this document's allocator (invariant 3), with fresh
/// UUIDs. Every reference that leaves the copy is re-pointed at this deck's own objects, never at a
/// copy of the source's (invariant 6: no new styles):
///
/// - a style, by its `style_identifier` and type, else by its name and type, when exactly one
///   style of this deck matches; any style without a match refuses the import, naming them all;
/// - the master (a template slide), by its name, when exactly one master here has it;
/// - the stylesheet, to this deck's document stylesheet;
/// - a reference the source itself leaves dangling, to a fresh identifier nothing uses (it stays
///   dangling instead of landing on an unrelated object here).
///
/// The slide's data (images, movies, audio) comes along under new data identifiers, sharing data
/// this deck already holds with the same digest. The copy therefore takes on this deck's theme, as
/// a slide pasted into a deck with another theme does when the styles match. Tables and charts take
/// this theme's preset of the same slot (`learnPresets`), and a table is registered with this
/// deck's calculation engine (`TableRegistration`, strict: a table whose formulas read another
/// table is refused). Refused for now: builds, and any outside reference of a kind no rule covers.
extension KeynoteDocument {
    static let objectContainerType: UInt32 = 11008, objectContainerIdentifier: UInt64 = 61

    public struct SlideImportReport: Equatable, Sendable {
        public var source: UInt64
        public var slide: UInt64
        public var node: UInt64
        public var component: String
        public var copiedObjects: Int
        /// Outside references re-pointed at this deck's styles, masters and stylesheet.
        public var mappedObjects: Int
        public var copiedData: Int
        public var sharedData: Int
    }

    public enum SlideImportFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case unmatchedStyles([String])
        case unmatchedMaster(String)
        case ambiguousMaster(String)
        case unsupportedContent(slide: UInt64, type: String)
        case unsupportedReference(type: String)
        case noStylesheet
        case unplaceable(String)

        public var description: String {
            switch self {
            case .unmatchedStyles(let styles):
                return "this deck has no match for \(styles.count) style(s) the slide uses: \(styles.joined(separator: ", ")); no styles are created (invariant 6)"
            case .unmatchedMaster(let name): return "this deck has no master named “\(name)”"
            case .ambiguousMaster(let name): return "this deck has more than one master named “\(name)”"
            case .unsupportedContent(let slide, let type): return "slide \(slide) holds \(type); Phase 3b imports slides without builds"
            case .unsupportedReference(let type): return "the slide references a \(type) outside itself, which Phase 3b has no rule to map"
            case .noStylesheet: return "this deck has no document stylesheet"
            case .unplaceable(let component): return "this deck has no component \(component) to hold the copy's objects"
            }
        }
    }

    @discardableResult
    public mutating func importSlide(at index: Int, from source: KeynoteDocument, to position: Int? = nil) throws -> SlideImportReport {
        if let newer = source.writtenByNewerKeynote {
            throw KeynoteError.schemaNewerThanLibrary(fileBuild: newer, pinned: "\(TypeRegistry.pinnedVersion) (\(TypeRegistry.pinnedBuild))")
        }
        let sourceList = try source.slideList()
        guard sourceList.indices.contains(index) else { throw SlideEditFailure.indexOutOfRange(index, count: sourceList.count) }
        let list = try slideList()
        let insertAt = position ?? list.count
        guard (0...list.count).contains(insertAt) else { throw SlideEditFailure.indexOutOfRange(insertAt, count: list.count) }
        let entry = sourceList[index]
        guard let sourceShow = source.showIdentifier, let showID = showIdentifier, var show = decoded(KN_ShowArchive.self, showID),
              var metadata = packageMetadata, let sourceMetadata = source.packageMetadata,
              let sourceRecords = source.store.records(in: entry.component), let nodeRecord = source.store.record(for: entry.node),
              let firstNode = show.slideTree.slides.first, let nodeComponent = store.entry(for: firstNode.identifier)?.component else {
            throw SlideEditFailure.unsupportedTree("no show, package metadata or slide records")
        }

        // What is copied, and what it may not hold yet.
        let roots = Set(sourceRecords.map(\.identifier)).union([entry.node])
        let copied = source.heldOnly(by: roots, referrers: source.referrerIndex(), keeping: [sourceShow])
        for id in copied.sorted() {
            guard let record = source.store.record(for: id) else { continue }
            for info in record.info.messageInfos where info.baseMessageIndex == nil {
                let name = source.registry?.name(for: info.type) ?? ""
                if (name.hasPrefix("TSCE.") && name != "TSCE.TrackedReferenceStoreArchive") || name.contains("Build") {
                    throw SlideImportFailure.unsupportedContent(slide: entry.slide, type: name)
                }
            }
        }

        // Fresh identifiers for the copies.
        var allocator = IDAllocator(seed: max(store.highestIdentifier, metadata.lastObjectIdentifier) + 1)
        var identifiers = [UInt64: UInt64]()
        for id in sourceRecords.map(\.identifier) { identifiers[id] = allocator.allocate() }
        identifiers[entry.node] = allocator.allocate()
        for id in copied.sorted() where identifiers[id] == nil { identifiers[id] = allocator.allocate() }

        // Every reference leaving the copy, re-pointed at this deck.
        // Tables among the copies, registered with this deck's calculation engine; their dependency
        // records may name no owner outside their own table (strict).
        let tables = try TableRegistration.plan(source: source, target: self, copied: copied, keeping: [sourceShow], strict: true,
                                                identifiers: &identifiers, allocator: &allocator)

        var resolver = try ForeignResolver(target: self)
        resolver.learnVariations(from: source)
        resolver.learnPresets(from: source)
        var unmatched = [String](), mapped = 0
        for id in copied.union(tables.engineCopies).sorted() {
            guard let record = source.store.record(for: id) else { continue }
            for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil && i < record.payloads.count {
                guard let derived = try? ReferenceDerivation.derive(type: info.type, payload: record.payloads[i]) else { continue }
                for ref in derived.objects where !copied.contains(ref) && identifiers[ref] == nil && ref != 0 {
                    guard source.store.entry(for: ref) != nil else {
                        identifiers[ref] = allocator.allocate()          // dangling in the source: stays dangling
                        continue
                    }
                    switch try resolver.resolve(ref, in: source) {
                    case .found(let target): identifiers[ref] = target; mapped += 1
                    case .unmatched(let what): if !unmatched.contains(what) { unmatched.append(what) }
                    }
                }
            }
        }
        if !unmatched.isEmpty { throw SlideImportFailure.unmatchedStyles(unmatched) }

        // UUIDs of the copied objects, fresh.
        var generator = SystemRandomNumberGenerator()
        var uuids = [ReferenceRewriter.UUIDValue: ReferenceRewriter.UUIDValue]()
        var newUUIDEntries = [String: [TSP_ObjectUUIDMapEntry]]()        // source locator → entries
        func locatorOf(_ c: TSP_ComponentInfo) -> String { c.locator.isEmpty ? c.preferredLocator : c.locator }
        for c in sourceMetadata.components {
            for e in c.objectUuidMapEntries {
                guard copied.contains(e.identifier), let new = identifiers[e.identifier] else { continue }
                let fresh = ReferenceRewriter.UUIDValue(lower: generator.next(), upper: generator.next())
                uuids[.init(lower: e.uuid.lower, upper: e.uuid.upper)] = fresh
                newUUIDEntries[locatorOf(c), default: []].append(TSP_ObjectUUIDMapEntry.with {
                    $0.identifier = new
                    $0.uuid = TSP_UUID.with { $0.lower = fresh.lower; $0.upper = fresh.upper }
                })
            }
        }

        // The slide's data: shared when this deck holds the same bytes, else copied under a new id.
        var dataIdentifiers = [UInt64: UInt64](), newData = [(TSP_DataInfo, Data)]()
        var sharedData = 0, nextData = metadata.datas.map(\.identifier).max() ?? 0
        let usedData = Set(copied.compactMap { source.store.record(for: $0) }.flatMap { $0.info.messageInfos.flatMap(\.dataReferences) })
        for old in usedData.sorted() where old != 0 {
            guard let info = sourceMetadata.datas.first(where: { $0.identifier == old }) else { continue }
            if info.hasDigest, let same = metadata.datas.first(where: { $0.hasDigest && $0.digest == info.digest }) {
                dataIdentifiers[old] = same.identifier
                sharedData += 1
                continue
            }
            nextData += 1
            var copy = info
            copy.identifier = nextData
            var bytes = Data()
            if let name = info.storedFileName, !name.isEmpty {
                guard let file = source.package.data("Data/" + name) else { continue }
                bytes = file
                let ext = (name as NSString).pathExtension
                let stem = Self.fileStem(info.preferredFileName.isEmpty ? name : info.preferredFileName, fallback: "data")
                copy.fileName = ext.isEmpty ? "\(stem)-\(nextData)" : "\(stem)-\(nextData).\(ext)"
                guard IWAPackage.isSafeEntryName("Data/" + copy.fileName) else { throw SlideImportFailure.unplaceable("Data/" + copy.fileName) }
            }
            dataIdentifiers[old] = nextData
            newData.append((copy, bytes))
        }

        // Each copied data item's metadata (its fallback colour) comes along: a fresh DataMetadata
        // object in this deck's map, as Keynote's own save would otherwise add.
        var dataMetadata = [(record: ArchiveRecord, data: UInt64)]()
        if sourceMetadata.hasDataMetadataMap, metadata.hasDataMetadataMap,
           let sourceMap = source.decoded(TSP_DataMetadataMap.self, sourceMetadata.dataMetadataMap.identifier) {
            let copiedData = Set(newData.map(\.0.identifier))
            for e in sourceMap.dataMetadataEntries {
                guard let new = dataIdentifiers[e.dataIdentifier], copiedData.contains(new),
                      var record = source.store.record(for: e.dataMetadata.identifier) else { continue }
                var info = record.info
                info.setIdentifier(allocator.allocate())
                record = ArchiveRecord(info: info, payloads: record.payloads, isDirty: true)
                dataMetadata.append((record, new))
            }
        }

        let rewriter = ReferenceRewriter(index: try FieldIndex.load(version: TypeRegistry.pinnedVersion), identifiers: identifiers, uuids: uuids,
                                         families: tables.families, ownerIDs: tables.ownerIDs, dataIdentifiers: dataIdentifiers)
        func copy(_ record: ArchiveRecord) throws -> ArchiveRecord {
            var info = record.info
            info.setIdentifier(identifiers[record.identifier]!)
            var payloads = record.payloads
            for (i, m) in info.messageInfos.enumerated() where i < payloads.count {
                if m.baseMessageIndex == nil, let type = Schema.messageType(for: m.type) {
                    payloads[i] = try rewriter.rewrite(payloads[i], message: type.protoMessageName)
                    if i == 0 { payloads[i] = try tables.withTableID(payloads[i], record: record.identifier) }
                }
                info.messageInfos[i] = try Self.remapped(m, identifiers: identifiers, dataIdentifiers: dataIdentifiers, length: UInt32(payloads[i].count))
            }
            return ArchiveRecord(info: info, payloads: payloads, isDirty: true)
        }

        // Placement: the slide's component becomes a new one; the node joins this deck's nodes; an
        // object alone in its source component gets a new component of its own; one in a shared
        // component joins this deck's component of the same name.
        let newSlide = identifiers[entry.slide]!, newNode = identifiers[entry.node]!
        let newLocator = "Slide-\(newSlide)"
        let newComponent = "Index/\(newLocator).iwa"
        let sourceLocator = String(entry.component.dropFirst("Index/".count).dropLast(".iwa".count))
        guard var info = sourceMetadata.components.first(where: { locatorOf($0) == sourceLocator }) else {
            throw SlideCloneFailure.noComponentInfo(entry.component)
        }
        var placements = [(record: ArchiveRecord, component: String, info: TSP_ComponentInfo?)]()
        var newComponentInfos = [TSP_ComponentInfo]()
        for id in copied.subtracting(roots).sorted() {
            guard let record = source.store.record(for: id), let home = source.store.entry(for: id)?.component,
                  let records = source.store.records(in: home) else { continue }
            let homeLocator = String(home.dropFirst("Index/".count).dropLast(".iwa".count))
            if records.count == 1, var own = sourceMetadata.components.first(where: { locatorOf($0) == homeLocator }) {
                own.identifier = identifiers[id]!
                own.locator = "\(own.preferredLocator.isEmpty ? homeLocator : own.preferredLocator)-\(identifiers[id]!)"
                guard IWAPackage.isSafeEntryName("Index/\(own.locator).iwa") else { throw SlideCloneFailure.unsafeLocator(own.locator) }
                own.objectUuidMapEntries = newUUIDEntries[homeLocator] ?? []
                own.externalReferences = []
                own.dataReferences = []
                placements.append((try copy(record), "Index/\(own.locator).iwa", own))
            } else {
                guard store.records(in: home) != nil || records.contains(where: { $0.info.messageInfos.first?.type == Self.objectContainerType }) else {
                    throw SlideImportFailure.unplaceable(home)
                }
                placements.append((try copy(record), home, nil))
            }
        }
        // An object container (charts keep their non-style archives in one: a component whose root
        // TSP.ObjectContainer lists its objects) gains the copies; this deck gets one, copied from
        // the source's, when it has none.
        var containers = [String: TSP_ObjectContainer]()               // component → its container, updated
        var containerIDs = [String: UInt64]()
        for p in placements where p.info == nil {
            if containers[p.component] == nil {
                if let records = store.records(in: p.component),
                   let root = records.first(where: { $0.info.messageInfos.first?.type == Self.objectContainerType }),
                   let container = decoded(TSP_ObjectContainer.self, root.identifier) {
                    containers[p.component] = container
                    containerIDs[p.component] = root.identifier
                } else if store.records(in: p.component) == nil,
                          let root = source.store.records(in: p.component)?.first(where: { $0.info.messageInfos.first?.type == Self.objectContainerType }),
                          var container = source.decoded(TSP_ObjectContainer.self, root.identifier),
                          var own = sourceMetadata.components.first(where: { "Index/\(locatorOf($0)).iwa" == p.component }) {
                    // Keynote's object container is always object 61 (as the document is 1 and the
                    // package metadata 2); a fresh identifier makes Keynote rewrite the deck on read.
                    let id = store.entry(for: Self.objectContainerIdentifier) == nil ? Self.objectContainerIdentifier : allocator.allocate()
                    container.objects = []
                    var info = root.info
                    info.setIdentifier(id)
                    let payload = try container.serializedData(partial: true)
                    info.messageInfos[0] = try Self.remapped(info.messageInfos[0], identifiers: [:], length: UInt32(payload.count))
                    store.addComponent(p.component, records: [ArchiveRecord(info: info, payloads: [payload], isDirty: true)])
                    own.identifier = id
                    own.objectUuidMapEntries = []
                    own.externalReferences = []
                    own.dataReferences = []
                    newComponentInfos.append(own)
                    containers[p.component] = container
                    containerIDs[p.component] = id
                }
            }
            containers[p.component]?.objects.append(TSP_Reference.with { $0.identifier = p.record.identifier })
        }
        store.addComponent(newComponent, records: try sourceRecords.map(copy))
        store.append(try copy(nodeRecord), to: nodeComponent)
        for p in placements {
            if p.info != nil { store.addComponent(p.component, records: [p.record]) } else { store.append(p.record, to: p.component) }
        }
        for (component, container) in containers {
            if let id = containerIDs[component] { try replacePayload(of: id, with: try container.serializedData(partial: true)) }
        }

        try tables.apply(to: &self, source: source, rewriter: rewriter, identifiers: identifiers, copy: copy)

        if !dataMetadata.isEmpty, let mapID = metadata.hasDataMetadataMap ? metadata.dataMetadataMap.identifier : nil,
           var map = decoded(TSP_DataMetadataMap.self, mapID), let home = store.entry(for: mapID)?.component {
            for (record, data) in dataMetadata {
                store.append(record, to: home)
                map.dataMetadataEntries.append(.with { $0.dataIdentifier = data; $0.dataMetadata = TSP_Reference.with { $0.identifier = record.identifier } })
            }
            try replacePayload(of: mapID, with: try map.serializedData(partial: true))
        }

        show.slideTree.slides.insert(TSP_Reference.with { $0.identifier = newNode }, at: insertAt)
        try replacePayload(of: showID, with: try show.serializedData(partial: true))
        metadata = packageMetadata ?? metadata

        // ComponentInfos: the slide's (external references and the data index are re-derived at
        // save), the new single-object components', and UUID-map entries where copies joined.
        info.identifier = newSlide
        info.locator = newLocator
        info.objectUuidMapEntries = newUUIDEntries[sourceLocator] ?? []
        info.externalReferences = []
        info.dataReferences = []
        metadata.components.append(info)
        metadata.components += placements.compactMap(\.info) + newComponentInfos
        let nodeLocator = String(nodeComponent.dropFirst("Index/".count).dropLast(".iwa".count))
        for p in placements where p.info == nil {
            let locator = String(p.component.dropFirst("Index/".count).dropLast(".iwa".count))
            guard let c = metadata.components.firstIndex(where: { locatorOf($0) == locator }),
                  let e = newUUIDEntries[locator]?.first(where: { $0.identifier == p.record.identifier }) else { continue }
            metadata.components[c].objectUuidMapEntries.append(e)
        }
        // The node gets a UUID-map entry when this deck's nodes have them.
        let nodes = Set(show.slideTree.slides.map(\.identifier))
        if let d = metadata.components.firstIndex(where: { locatorOf($0) == nodeLocator }),
           metadata.components[d].objectUuidMapEntries.contains(where: { nodes.contains($0.identifier) }) {
            metadata.components[d].objectUuidMapEntries.append(TSP_ObjectUUIDMapEntry.with {
                $0.identifier = newNode
                $0.uuid = TSP_UUID.with { $0.lower = generator.next(); $0.upper = generator.next() }
            })
        }
        metadata.lastObjectIdentifier = max(metadata.lastObjectIdentifier, allocator.highWaterMark)
        _ = try commitData(newData, replacing: [], metadata: &metadata)
        return SlideImportReport(source: entry.slide, slide: newSlide, node: newNode, component: newComponent,
                                 copiedObjects: copied.count, mappedObjects: mapped, copiedData: newData.count, sharedData: sharedData)
    }
}

/// Finds this deck's counterpart of an object another deck's slide refers to (see importSlide).
struct ForeignResolver {
    enum Resolution { case found(UInt64), unmatched(String) }

    let target: KeynoteDocument
    let stylesheet: UInt64
    var byIdentifier = [UInt32: [String: [UInt64]]]()
    var byName = [UInt32: [String: [UInt64]]]()
    var masters = [String: [UInt64]]()
    /// Source style → this deck's style, for the anonymous variations a master's placeholders use
    /// (filled by `learnVariations`).
    var variations = [UInt64: UInt64]()
    /// Source object → this deck's object at the same preset position (`learnPresets`): presets
    /// and the unnamed styles under them.
    var presets = [UInt64: UInt64]()
    var variationsByParent = [UInt64: [UInt64]]()                 // this deck: parent → variations

    static let slideType: UInt32 = 5, placeholderType: UInt32 = 7, themeType: UInt32 = 10, stylesheetType: UInt32 = 401

    init(target: KeynoteDocument) throws {
        self.target = target
        var stylesheet: UInt64?
        for id in target.store.identifiers {
            guard let record = target.store.record(for: id), let type = record.info.messageInfos.first?.type,
                  let component = target.store.entry(for: id)?.component else { continue }
            if type == Self.stylesheetType, component == "Index/DocumentStylesheet.iwa" { stylesheet = id }
            if type == Self.slideType, component.hasPrefix("Index/TemplateSlide"),
               let slide = target.decoded(KN_SlideArchive.self, id), slide.hasName {
                masters[slide.name, default: []].append(id)
            }
            if let style = Self.styleSuper(record) {
                if style.isVariation, style.hasParent { variationsByParent[style.parent.identifier, default: []].append(id) }
                if style.hasStyleIdentifier { byIdentifier[type, default: [:]][style.styleIdentifier, default: []].append(id) }
                if style.hasName { byName[type, default: [:]][style.name, default: []].append(id) }
            }
        }
        guard let stylesheet else { throw KeynoteDocument.SlideImportFailure.noStylesheet }
        self.stylesheet = stylesheet
    }

    func resolve(_ id: UInt64, in source: KeynoteDocument) throws -> Resolution {
        guard let record = source.store.record(for: id), let type = record.info.messageInfos.first?.type else {
            throw KeynoteDocument.SlideImportFailure.unsupportedReference(type: "missing object")
        }
        let typeName = source.registry?.name(for: type) ?? "type \(type)"
        if type == Self.stylesheetType { return .found(stylesheet) }
        if type == Self.slideType {
            guard let slide = source.decoded(KN_SlideArchive.self, id), slide.hasName else {
                throw KeynoteDocument.SlideImportFailure.unsupportedReference(type: "unnamed \(typeName)")
            }
            guard let found = masters[slide.name] else { throw KeynoteDocument.SlideImportFailure.unmatchedMaster(slide.name) }
            guard found.count == 1 else { throw KeynoteDocument.SlideImportFailure.ambiguousMaster(slide.name) }
            return .found(found[0])
        }
        guard let style = Self.styleSuper(record) else {
            if let found = presets[id] { return .found(found) }                   // a preset
            throw KeynoteDocument.SlideImportFailure.unsupportedReference(type: typeName)
        }
        if style.hasStyleIdentifier, let found = byIdentifier[type]?[style.styleIdentifier], found.count == 1 { return .found(found[0]) }
        if style.hasName, let found = byName[type]?[style.name], found.count == 1 { return .found(found[0]) }
        // The style the counterpart in this deck's same-named master uses for the same role: a match
        // by role, for any style (Kyoto's title placeholder style "Title Alt" → this master's title
        // style).
        if let found = variations[id] { return .found(found) }
        // The style at the same preset position stands in only for an unnamed style (anonymous, or
        // with only an internal identifier such as a chart preset's "chart-0-paragraphStyle_20"):
        // position is weaker evidence than a name or a role.
        if !style.hasName, let found = presets[id] { return .found(found) }
        // A variation this deck holds too: same type, the counterpart parent, the same bytes once
        // its parent and stylesheet are re-pointed here.
        if style.isVariation, style.hasParent, case .found(let parent)? = try? resolve(style.parent.identifier, in: source),
           let candidates = variationsByParent[parent], let message = Schema.messageType(for: type),
           let payload = record.payloads.first, let index = FieldIndexCache.index {
            var map = [style.parent.identifier: parent]
            if style.hasStylesheet { map[style.stylesheet.identifier] = stylesheet }
            let moved = try ReferenceRewriter(index: index, identifiers: map).rewrite(payload, message: message.protoMessageName)
            if let same = candidates.first(where: { target.store.record(for: $0)?.info.messageInfos.first?.type == type
                                                     && target.store.record(for: $0)?.payloads.first == moved }) {
                return .found(same)
            }
        }
        var label = style.hasName ? style.name : (style.hasStyleIdentifier ? style.styleIdentifier : "unnamed")
        if !style.hasName, !style.hasStyleIdentifier, style.hasParent, let parent = source.store.record(for: style.parent.identifier),
           let p = Self.styleSuper(parent) {
            label = "variation of \(p.hasName ? p.name : p.styleIdentifier)"
        }
        return .unmatched("\(typeName) “\(label)”")
    }

    /// Anonymous style variations, learned from the masters: every master of the source paired with
    /// this deck's master of the same name, their placeholders paired by kind and their other
    /// drawables by type in order, and each style a source object uses mapped to the style its
    /// counterpart uses in the same field. A style seen under several counterparts takes the one
    /// most of them use. The copy keeps each object's role and takes on this deck's look for it.
    mutating func learnVariations(from source: KeynoteDocument) {
        func masters(_ d: KeynoteDocument) -> [String: UInt64] {
            var out = [String: UInt64](), seen = Set<String>()
            for id in d.store.identifiers where d.store.record(for: id)?.info.messageInfos.first?.type == Self.slideType {
                guard d.store.entry(for: id)?.component.hasPrefix("Index/TemplateSlide") == true,
                      let slide = d.decoded(KN_SlideArchive.self, id), slide.hasName else { continue }
                if seen.insert(slide.name).inserted { out[slide.name] = id } else { out[slide.name] = nil }   // unique names only
            }
            return out
        }
        func roles(_ d: KeynoteDocument, _ master: UInt64) -> [String: [UInt64]] {
            guard let component = d.store.entry(for: master)?.component, let records = d.store.records(in: component) else { return [:] }
            var out = [String: [UInt64]]()
            for r in records {
                guard let type = r.info.messageInfos.first?.type, type != Self.slideType else { continue }
                if type == Self.placeholderType, let p = d.decoded(KN_PlaceholderArchive.self, r.identifier) {
                    out["placeholder \(p.kind.rawValue)", default: []].append(r.identifier)
                } else {
                    out["type \(type)", default: []].append(r.identifier)
                }
            }
            return out
        }
        func styles(_ d: KeynoteDocument, _ id: UInt64) -> [(String, UInt64)] {
            guard let r = d.store.record(for: id), let derived = try? ReferenceDerivation.derive(type: r.info.messageInfos[0].type, payload: r.payloads[0]) else { return [] }
            return zip(derived.objectFields, derived.objects).filter { d.store.record(for: $0.1).flatMap(Self.styleSuper) != nil }
        }
        var votes = [UInt64: [UInt64: Int]]()
        let theirs = masters(target)
        for (name, sourceMaster) in masters(source) {
            guard let targetMaster = theirs[name] else { continue }
            let mine = roles(source, sourceMaster), counterparts = roles(target, targetMaster)
            for (role, sources) in mine {
                guard let targets = counterparts[role] else { continue }
                for (s, t) in zip(sources, targets) {
                    var pool = styles(target, t)
                    for (field, style) in styles(source, s) {
                        guard let k = pool.firstIndex(where: { $0.0 == field }) else { continue }
                        votes[style, default: [:]][pool.remove(at: k).1, default: 0] += 1
                    }
                }
            }
        }
        for (style, counts) in votes {
            variations[style] = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
        }
    }

    /// Presets and the anonymous styles under them, learned from the themes: every Apple theme lists
    /// the same preset slots (six table, six chart, … presets), so the source theme's presets pair
    /// with this deck's by field and position, and everything under a pair (a table preset's style
    /// network and its cell, table and paragraph styles; a chart preset's chart, legend, axis and
    /// series styles) pairs field by field in order, recursively, objects of the same type only.
    /// A table or chart then takes on this theme's preset of the same slot.
    mutating func learnPresets(from source: KeynoteDocument) {
        func theme(_ d: KeynoteDocument) -> UInt64? {
            d.store.identifiers.first { d.store.record(for: $0)?.info.messageInfos.first?.type == Self.themeType }
        }
        func references(_ d: KeynoteDocument, _ id: UInt64) -> [String: [UInt64]] {
            guard let r = d.store.record(for: id), let derived = try? ReferenceDerivation.derive(type: r.info.messageInfos[0].type, payload: r.payloads[0]) else { return [:] }
            var out = [String: [UInt64]]()
            for (ref, field) in zip(derived.objects, derived.objectFields) { out[field, default: []].append(ref) }
            return out
        }
        func type(_ d: KeynoteDocument, _ id: UInt64) -> UInt32? { d.store.record(for: id)?.info.messageInfos.first?.type }
        guard let mine = theme(source), let theirs = theme(target) else { return }
        var votes = [UInt64: [UInt64: Int]](), visited = Set<UInt64>()
        func walk(_ a: UInt64, _ b: UInt64, depth: Int) {
            guard depth < 8, type(source, a) != nil, type(source, a) == type(target, b) else { return }
            votes[a, default: [:]][b, default: 0] += 1
            guard visited.insert(a).inserted else { return }
            let left = references(source, a), right = references(target, b)
            for (field, refs) in left {
                guard let others = right[field] else { continue }
                for (x, y) in zip(refs, others) { walk(x, y, depth: depth + 1) }
            }
        }
        let left = references(source, mine), right = references(target, theirs)
        for (field, refs) in left where field.contains("PresetsArchive.") {
            guard let others = right[field] else { continue }
            for (x, y) in zip(refs, others) { walk(x, y, depth: 0) }
        }
        for (object, counts) in votes {
            presets[object] = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
        }
    }

    /// The `TSS.StyleArchive` at the root of a style archive's `super` chain (field 1, possibly
    /// through intermediate supers: TSWP.ShapeStyleArchive → TSD.ShapeStyleArchive → TSS), when the
    /// record is a style.
    static func styleSuper(_ record: ArchiveRecord) -> TSS_StyleArchive? {
        guard let type = record.info.messageInfos.first?.type, var name = Schema.messageType(for: type)?.protoMessageName,
              let index = FieldIndexCache.index, var bytes = record.payloads.first.map({ [UInt8]($0) }) else { return nil }
        for _ in 0..<8 {
            guard let sub = index.subMessage(of: name, field: 1), let field = fieldOne(bytes) else { return nil }
            if sub == "TSS.StyleArchive" { return try? TSS_StyleArchive(serializedBytes: Data(field), partial: true) }
            name = sub
            bytes = field
        }
        return nil
    }

    /// The bytes of field 1 (length-delimited) of a serialized message.
    static func fieldOne(_ b: [UInt8]) -> [UInt8]? {
        var i = b.startIndex
        while i < b.endIndex {
            guard let (tag, afterTag) = ReferenceRewriter.varint(b[...], i) else { return nil }
            if tag == 0x0A, let (n, start) = ReferenceRewriter.varint(b[...], afterTag), n <= UInt64(b.endIndex - start) {
                return Array(b[start..<(start + Int(n))])
            }
            guard let end = ReferenceRewriter.fieldEnd(b[...], tag: tag, afterTag: afterTag) else { return nil }
            i = end
        }
        return nil
    }
}

/// The pinned field index, loaded once.
enum FieldIndexCache {
    static let index: FieldIndex? = try? FieldIndex.load(version: TypeRegistry.pinnedVersion)
}
