import Foundation
import IWAArchive
import IWAContainer
import IWASchema
import IWASnappy
import SwiftProtobuf

/// Errors raised by `KeynoteDocument`.
public enum KeynoteError: Error, Equatable, Sendable {
    /// The validator found problems; nothing was written (invariant 8).
    case validationFailed([ValidationIssue])
    /// The file was written by a newer Keynote than the pinned schema (AT-25); reads only.
    case schemaNewerThanLibrary(fileBuild: String, pinned: String)
    /// No object with this identifier.
    case noSuchObject(UInt64)
    /// The payload cannot be replaced: no such message, a merge diff descriptor, or an object with
    /// merge records attached (consolidation is not implemented).
    case notMutable(UInt64, reason: String)
    /// The new payload's references could not be derived (invariant 4).
    case referencesNotDerivable(UInt64, detail: String)
    /// One `.iwa` could not be read. `detail` is the lower layer's error, whose offsets are
    /// relative to that stage's input (the compressed file, or its decompressed stream).
    case componentUnreadable(component: String, stage: ComponentStage, detail: String)

    public enum ComponentStage: String, Equatable, Sendable {
        /// Chunk framing or Snappy (`IWAChunking.decompress`).
        case decompress
        /// Record split (`ArchiveStream.split`: varints, `ArchiveInfo`, payload lengths).
        case split
    }
}

extension KeynoteError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .validationFailed(let issues):
            return "validation failed with \(issues.count) error(s); nothing was written"
                + issues.prefix(5).map { "\n  \($0)" }.joined()
        case .schemaNewerThanLibrary(let fileBuild, let pinned):
            return "saved by \(fileBuild), newer than the pinned schema \(pinned); read-only"
        case .componentUnreadable(let component, let stage, let detail):
            return "\(component): \(stage.rawValue) failed: \(detail)"
        case .noSuchObject(let id):
            return "no object \(id)"
        case .notMutable(let id, let reason):
            return "object \(id) cannot be replaced: \(reason)"
        case .referencesNotDerivable(let id, let detail):
            return "object \(id): references not derivable: \(detail)"
        }
    }
}

/// A Keynote document: its container plus the raw object store built from every `Index/*.iwa`.
///
/// Phase 0 scope: open, inspect, validate, save. Nothing here decodes a payload with a schema yet;
/// the typed graph (`Show`, `Slide`, `Drawable`, `TextStorage`) arrives with `IWASchema`'s first
/// generated module. Everything that works today works without one (invariants 1 and 2).
public struct KeynoteDocument: Sendable {
    public internal(set) var package: IWAPackage
    public internal(set) var store: ObjectStore
    public let registry: TypeRegistry?

    /// The Keynote build that last saved this file, from `BuildVersionHistory.plist` (e.g. "M15.4-7051-1").
    public var lastSavedBy: String? { package.buildVersionHistory.last }

    public static func open(_ url: URL) throws -> KeynoteDocument {
        return try open(IWAPackage.open(url))
    }

    public static func open(_ package: IWAPackage) throws -> KeynoteDocument {
        var store = ObjectStore()
        for name in package.iwaNames {
            guard let compressed = package.data(name) else {
                throw KeynoteError.componentUnreadable(component: name, stage: .decompress, detail: "entry has no data")
            }
            let decompressed: Data
            do {
                decompressed = try IWAChunking.decompress(compressed)
            } catch {
                throw KeynoteError.componentUnreadable(component: name, stage: .decompress, detail: "\(error)")
            }
            do {
                try store.load(component: name, decompressed: decompressed)
            } catch {
                throw KeynoteError.componentUnreadable(component: name, stage: .split, detail: "\(error)")
            }
        }
        store.finalize()
        let registry = try? TypeRegistry.load(version: TypeRegistry.pinnedVersion)
        return KeynoteDocument(package: package, store: store, registry: registry)
    }

    init(package: IWAPackage, store: ObjectStore, registry: TypeRegistry?) {
        self.package = package
        self.store = store
        self.registry = registry
    }

    // MARK: Package metadata

    /// `TSP.PackageMetadata`, identifier 2 (type 11006 in `Index/Metadata.iwa` in every corpus
    /// deck): the component list, every `DataInfo`, and the read, write and file-format versions
    /// Keynote checks before opening a file. Nil if the object is missing or does not decode.
    public var packageMetadata: TSP_PackageMetadata? {
        guard let record = store.record(for: 2), let info = record.info.messageInfos.first,
              info.type == Self.packageMetadataType, let payload = record.payloads.first else { return nil }
        return try? TSP_PackageMetadata(serializedBytes: payload, extensions: Schema.extensions, partial: true)
    }

    static let packageMetadataType: UInt32 = 11006

    /// AT-25: non-nil (a description of the file's versions) when a newer Keynote than the pinned
    /// schema wrote this file. Such a document reads through the raw store and refuses `save`.
    public var writtenByNewerKeynote: String? {
        guard let m = packageMetadata else { return nil }
        guard TypeRegistry.isNewer(m.fileFormatVersion, than: TypeRegistry.pinnedFileFormatVersion) else { return nil }
        return "\(lastSavedBy ?? "unknown build") (file format \(m.fileFormatVersion.map(String.init).joined(separator: ".")))"
    }

    /// True when every save in `BuildVersionHistory` is the pinned Keynote (a `Template: …` origin is
    /// allowed): then every object was archived by it, and its reference lists show the pinned
    /// Keynote's own strength rule. Older saves leave records it never re-archived.
    public var authoredByPinnedKeynote: Bool {
        let history = package.buildVersionHistory
        return !history.isEmpty && history.allSatisfy { $0.hasPrefix("Template:") || $0.hasPrefix("M\(TypeRegistry.pinnedVersion)-") }
    }

    // MARK: Mutation

    /// Replaces one payload of an object, the single primitive every later surgery builds on.
    ///
    /// The header follows from the bytes, never the other way round: `length` is the new size,
    /// `data_references` are the derived DataReference ids minus 0, and `object_references` are the
    /// strong references by the invariant-4 rule (mixed fields keep the membership the old payload
    /// had). Lists keep their stored order for references that remain, so an edit that moves no
    /// reference leaves the header byte-identical; new ones follow in traversal order.
    public mutating func replacePayload(of identifier: UInt64, message index: Int = 0, with payload: Data) throws {
        guard let entry = store.entry(for: identifier), var record = store.record(for: identifier) else {
            throw KeynoteError.noSuchObject(identifier)
        }
        guard entry.merges.isEmpty else { throw KeynoteError.notMutable(identifier, reason: "merge records attached") }
        guard index < record.info.messageInfos.count, index < record.payloads.count else {
            throw KeynoteError.notMutable(identifier, reason: "no message \(index)")
        }
        var info = record.info.messageInfos[index]
        guard info.baseMessageIndex == nil else { throw KeynoteError.notMutable(identifier, reason: "message \(index) is a merge diff descriptor") }
        let strength: ReferenceStrength
        do { strength = try ReferenceStrength.load(version: TypeRegistry.pinnedVersion) } catch {
            throw KeynoteError.referencesNotDerivable(identifier, detail: "\(error)")
        }
        let old: DerivedReferences, new: DerivedReferences, listed: Set<UInt64>
        do {
            old = try ReferenceDerivation.derive(type: info.type, payload: record.payloads[index])
            new = try ReferenceDerivation.derive(type: info.type, payload: payload)
            listed = try ReferenceDerivation.listedObjects(new, strength: strength, original: (old, info.objectReferences))
        } catch {
            throw KeynoteError.referencesNotDerivable(identifier, detail: "\(error)")
        }
        info.setLength(UInt32(payload.count))
        info.setObjectReferences(Self.stableOrder(listed, stored: info.objectReferences, traversal: new.objects))
        // data_references: one entry per occurrence, as Keynote 15.4 writes them (all 141,941 lists in
        // the decks it alone saved); an unchanged multiset keeps its stored order.
        let occurrences = new.data.filter { $0 != 0 }
        if occurrences.sorted() != info.dataReferences.sorted() { info.setDataReferences(occurrences) }
        record.info.messageInfos[index] = info
        record.payloads[index] = payload
        store.replaceRecord(for: identifier, with: record)
    }

    /// `members` ordered as `stored` where they were already listed, the rest in traversal order.
    static func stableOrder(_ members: Set<UInt64>, stored: [UInt64], traversal: [UInt64]) -> [UInt64] {
        var out = [UInt64](), seen = Set<UInt64>()
        for ref in stored + traversal where members.contains(ref) && seen.insert(ref).inserted { out.append(ref) }
        return out
    }

    // MARK: Identifiers

    /// A fresh allocator seeded above every identifier in the store (invariant 3). Phase 0 has no
    /// `PackageMetadata` decode yet, so the seed is the store's high-water mark; once the typed
    /// layer lands it must also read `last_object_identifier` and take the larger.
    public func makeIDAllocator() -> IDAllocator {
        IDAllocator(seed: store.highestIdentifier + 1)
    }

    // MARK: Validation

    public func validate() -> [ValidationIssue] {
        Validator.validate(self)
    }

    // MARK: Save

    /// Writes the document. Every component is re-joined from the store; untouched records are
    /// emitted from their original bytes. The component data index and the external references of
    /// every changed component are brought up to date first (invariant 4). Refuses on any validation issue.
    public func save(to url: URL, as form: IWAPackage.Form? = nil) throws {
        if let newer = writtenByNewerKeynote {
            throw KeynoteError.schemaNewerThanLibrary(fileBuild: newer, pinned: "\(TypeRegistry.pinnedVersion) (\(TypeRegistry.pinnedBuild))")
        }
        var document = self
        try document.refreshComponentDataIndex()
        try document.refreshExternalReferences()
        try document.write(to: url, as: form)
    }

    /// The document as the bytes of a single-file `.key` (a zip), with the same checks and derived
    /// lists as `save`: for a host that keeps documents in memory or writes them itself.
    public func serializedData() throws -> Data {
        if let newer = writtenByNewerKeynote {
            throw KeynoteError.schemaNewerThanLibrary(fileBuild: newer, pinned: "\(TypeRegistry.pinnedVersion) (\(TypeRegistry.pinnedBuild))")
        }
        var document = self
        try document.refreshComponentDataIndex()
        try document.refreshExternalReferences()
        return try document.joinedPackage().zipData()
    }

    private func write(to url: URL, as form: IWAPackage.Form?) throws {
        try joinedPackage().write(to: url, as: form)
    }

    /// The package with every component re-joined from the store; refuses on a validation error.
    private func joinedPackage() throws -> IWAPackage {
        let issues = validate().filter { $0.severity == .error }
        guard issues.isEmpty else { throw KeynoteError.validationFailed(issues) }
        var out = package
        for (name, decompressed) in store.joinedComponents() {
            out.set(name, try IWAChunking.compress(decompressed))
        }
        return out
    }

    /// `PackageMetadata.components[].data_references` indexes, per component, which objects use
    /// which data and how often; Keynote trusts it when loading data, and a stale entry makes it ask
    /// for data that is gone. For every changed (dirty) object, its entries are rebuilt from its
    /// payload's occurrences; entries for untouched objects stay as Keynote wrote them. In the decks
    /// 15.4 alone saved, every component's index equals this derivation.
    mutating func refreshComponentDataIndex() throws {
        var dirty = [String: [UInt64: [UInt64: UInt32]]]()      // locator → object → data → count
        for component in store.components {
            let locator = String(component.name.dropFirst("Index/".count).dropLast(".iwa".count))
            for record in component.records where record.isDirty {
                var counts = [UInt64: UInt32]()
                for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil {
                    guard let d = try? ReferenceDerivation.derive(type: info.type, payload: record.payloads[i]) else { continue }
                    for id in d.data where id != 0 { counts[id, default: 0] += 1 }
                }
                dirty[locator, default: [:]][record.identifier] = counts
            }
        }
        guard !dirty.isEmpty, var metadata = packageMetadata else { return }
        let before = metadata
        for c in metadata.components.indices {
            let locator = metadata.components[c].locator.isEmpty ? metadata.components[c].preferredLocator : metadata.components[c].locator
            guard let objects = dirty[locator] else { continue }
            var entries = metadata.components[c].dataReferences
            for e in entries.indices {
                entries[e].objectReferenceList.removeAll { objects[$0.objectIdentifier] != nil }
            }
            for (object, counts) in objects.sorted(by: { $0.key < $1.key }) {
                for (data, count) in counts.sorted(by: { $0.key < $1.key }) {
                    let reference = TSP_ComponentDataReference.ObjectReference.with { $0.objectIdentifier = object; $0.count = count }
                    if let e = entries.firstIndex(where: { $0.dataIdentifier == data }) {
                        entries[e].objectReferenceList.append(reference)
                    } else {
                        entries.append(TSP_ComponentDataReference.with { $0.dataIdentifier = data; $0.objectReferenceList = [reference] })
                    }
                }
            }
            entries.removeAll { $0.objectReferenceList.isEmpty }
            metadata.components[c].dataReferences = entries
        }
        if metadata != before { try replacePayload(of: 2, with: try metadata.serializedData(partial: true)) }
    }

    // MARK: Inspection

    public struct Summary: Sendable, Equatable {
        public var components: [String]
        public var objectCount: Int
        public var recordCount: Int
        public var mergeRecordCount: Int
        /// Objects that exist only as merge records (no non-merge base).
        public var mergeOnlyObjectCount: Int
        public var highestIdentifier: UInt64
        public var typeHistogram: [UInt32: Int]
        public var buildVersionHistory: [String]
        public var fileFormatVersion: String?
        public var documentIdentifier: String?
        public var dataEntries: Int
    }

    public var summary: Summary {
        var records = 0
        var merges = 0
        for component in store.components {
            records += component.records.count
            merges += component.records.filter(\.shouldMerge).count
        }
        return Summary(
            components: store.componentNames,
            objectCount: store.objectCount,
            recordCount: records,
            mergeRecordCount: merges,
            mergeOnlyObjectCount: store.mergeOnlyIdentifiers.count,
            highestIdentifier: store.highestIdentifier,
            typeHistogram: store.typeHistogram,
            buildVersionHistory: package.buildVersionHistory,
            fileFormatVersion: package.fileFormatVersion,
            documentIdentifier: package.documentIdentifier,
            dataEntries: package.dataNames.count)
    }
}

/// Allocates object identifiers above everything already in use (invariant 3). One per document;
/// the high-water mark is written back to `PackageMetadata.last_object_identifier` on save.
public struct IDAllocator: Sendable, Equatable {
    public private(set) var next: UInt64

    public init(seed: UInt64) {
        self.next = seed
    }

    public mutating func allocate() -> UInt64 {
        defer { next += 1 }
        return next
    }

    /// The last identifier handed out, or `seed - 1` if none.
    public var highWaterMark: UInt64 { next - 1 }
}
