import Foundation
import IWASnappy

/// Problems an `ObjectStore` finds while indexing (reported, never fatal on read).
public enum StoreIssue: Equatable, Sendable {
    /// Two non-merge records carry the same identifier.
    case duplicateIdentifier(UInt64, components: [String])
}

/// The raw object store: every record from every component, indexed by identifier.
///
/// Two-pass semantics as Keynote applies them: non-merge records define objects; `should_merge`
/// records attach to the object with the same identifier and are applied on typed decode (never
/// folded into the raw bytes, so the original stays available for re-emission). A merge record
/// whose identifier has no base is the object: Keynote writes plenty of these (stylesheet
/// components are full of them), and prior art treats the first encounter as the base.
public struct ObjectStore: Sendable {
    /// A component is one `.iwa` file; name is the entry name under `Index/`.
    public struct Component: Sendable {
        public let name: String
        public var records: [ArchiveRecord]
    }

    public struct Entry: Sendable {
        public let component: String
        public let index: Int
        public var merges: [(component: String, index: Int)]
    }

    public private(set) var components: [Component] = []
    public private(set) var byIdentifier: [UInt64: Entry] = [:]
    public private(set) var issues: [StoreIssue] = []
    private var pendingMerges: [(identifier: UInt64, component: String, index: Int)] = []

    public init() {}

    /// Adds a component's decompressed stream. Call `finalize()` after the last one.
    public mutating func load(component name: String, decompressed: Data) throws {
        let records = try ArchiveStream.split(decompressed)
        components.append(Component(name: name, records: records))
        for (i, record) in records.enumerated() {
            if record.shouldMerge {
                pendingMerges.append((record.identifier, name, i))
            } else if let existing = byIdentifier[record.identifier] {
                issues.append(.duplicateIdentifier(record.identifier, components: [existing.component, name]))
            } else {
                byIdentifier[record.identifier] = Entry(component: name, index: i, merges: [])
            }
        }
    }

    /// Attaches merge records to their base objects; a merge with no base becomes the base.
    public mutating func finalize() {
        for merge in pendingMerges {
            if var entry = byIdentifier[merge.identifier] {
                entry.merges.append((merge.component, merge.index))
                byIdentifier[merge.identifier] = entry
            } else {
                byIdentifier[merge.identifier] = Entry(component: merge.component, index: merge.index, merges: [])
            }
        }
        pendingMerges.removeAll()
    }

    /// Base objects whose base record is itself a merge record (no non-merge record exists).
    public var mergeOnlyIdentifiers: [UInt64] {
        byIdentifier.compactMap { id, entry in
            (records(in: entry.component)?[entry.index].shouldMerge ?? false) ? id : nil
        }.sorted()
    }

    public var componentNames: [String] { components.map(\.name) }

    public var objectCount: Int { byIdentifier.count }

    public var identifiers: [UInt64] { byIdentifier.keys.sorted() }

    public var highestIdentifier: UInt64 { byIdentifier.keys.max() ?? 0 }

    /// The base record for an identifier (merges are listed in `entry(for:)?.merges`).
    public func record(for identifier: UInt64) -> ArchiveRecord? {
        guard let entry = byIdentifier[identifier] else { return nil }
        return records(in: entry.component)?[entry.index]
    }

    public func entry(for identifier: UInt64) -> Entry? { byIdentifier[identifier] }

    public func records(in component: String) -> [ArchiveRecord]? {
        components.first(where: { $0.name == component })?.records
    }

    /// Replaces a record in place (same component and position) and marks it dirty.
    public mutating func replaceRecord(for identifier: UInt64, with record: ArchiveRecord) {
        guard let entry = byIdentifier[identifier],
              let c = components.firstIndex(where: { $0.name == entry.component }) else { return }
        var updated = record
        updated.isDirty = true
        components[c].records[entry.index] = updated
    }

    /// Count of base objects per message type (first message of each record).
    public var typeHistogram: [UInt32: Int] {
        var histogram = [UInt32: Int]()
        for entry in byIdentifier.values {
            if let record = records(in: entry.component)?[entry.index], let first = record.info.messageInfos.first {
                histogram[first.type, default: 0] += 1
            }
        }
        return histogram
    }

    /// Every (from, to) object reference declared in headers whose target is not in the store.
    public var danglingObjectReferences: [(from: UInt64, to: UInt64)] {
        var dangling = [(from: UInt64, to: UInt64)]()
        for component in components {
            for record in component.records {
                for info in record.info.messageInfos {
                    for target in info.objectReferences where byIdentifier[target] == nil {
                        dangling.append((record.identifier, target))
                    }
                }
            }
        }
        return dangling
    }

    /// Joins every component back to its decompressed stream, in load order.
    public func joinedComponents() -> [(name: String, decompressed: Data)] {
        components.map { ($0.name, ArchiveStream.join($0.records)) }
    }
}
