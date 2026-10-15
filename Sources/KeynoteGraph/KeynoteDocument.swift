import Foundation
import IWAArchive
import IWAContainer
import IWASchema
import IWASnappy

/// Errors raised by `KeynoteDocument`.
public enum KeynoteError: Error, Equatable, Sendable {
    /// The validator found problems; nothing was written (invariant 8).
    case validationFailed([ValidationIssue])
    /// The file was written by a newer Keynote than the pinned schema (AT-25); reads only.
    case schemaNewerThanLibrary(fileBuild: String, pinned: String)
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
        }
    }
}

/// A Keynote document: its container plus the raw object store built from every `Index/*.iwa`.
///
/// Phase 0 scope: open, inspect, validate, save. Nothing here decodes a payload with a schema yet;
/// the typed graph (`Show`, `Slide`, `Drawable`, `TextStorage`) arrives with `IWASchema`'s first
/// generated module. Everything that works today works without one (invariants 1 and 2).
public struct KeynoteDocument: Sendable {
    public private(set) var package: IWAPackage
    public private(set) var store: ObjectStore
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
    /// emitted from their original bytes. Refuses on any validation issue.
    public func save(to url: URL, as form: IWAPackage.Form? = nil) throws {
        let issues = validate().filter { $0.severity == .error }
        guard issues.isEmpty else { throw KeynoteError.validationFailed(issues) }
        var out = package
        for (name, decompressed) in store.joinedComponents() {
            out.set(name, try IWAChunking.compress(decompressed))
        }
        try out.write(to: url, as: form)
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
