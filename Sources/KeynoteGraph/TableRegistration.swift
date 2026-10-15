import Foundation
import IWAArchive
import IWASchema
import SwiftProtobuf

/// Registering copied tables with a calculation engine, as Keynote's own duplicate does (see
/// `cloneSlide`): each copied table gets a fresh `table_id`, and its formula-owner family (the
/// table_id UUID plus per-kind offsets in the low word) moves with it; every owner-ID map entry of
/// the family gets a twin under a fresh internal identifier; the family's dependency records and
/// the tiles only they hold are copied with UUIDs and internal identifiers moved; the family's
/// UUID-map entries are copied too. Planned before the copies are rewritten (it allocates their
/// identifiers), applied after. Source and target are the same document for clone, different ones
/// for import.
struct TableRegistration {
    enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case noCalculationEngine
        /// A copied table's dependency records name an owner outside its own family (a formula
        /// reading another table); across decks that owner's internal identifier means nothing.
        case foreignOwner(table: String)

        var description: String {
            switch self {
            case .noCalculationEngine: return "a table needs a calculation engine, and the deck has none"
            case .foreignOwner(let table):
                return "table “\(table)” has formulas that read another table; Phase 3b imports only self-contained tables"
            }
        }
    }

    var families = [ReferenceRewriter.UUIDFamily]()
    /// Source table model → its new table_id.
    var tableIDs = [UInt64: String]()
    /// Source internal owner identifier → the new one in the target's engine.
    var ownerIDs = [UInt64: UInt64]()
    /// Source dependency records to copy and list in the target's tracker.
    var dependencies = [UInt64]()
    /// Every source object copied into the target engine's component (records and their tiles).
    var engineCopies = [UInt64]()
    var mapEntries = [TSCE_OwnerIDMapArchive.OwnerIDMapArchiveEntry]()
    var uuidReferences = [TSCE_UuidReferenceMapArchive.CellRefsForUuid]()
    var targetEngine: UInt64 = 0

    var isEmpty: Bool { families.isEmpty }

    static func uuid(_ o: TSP_CFUUIDArchive) -> ReferenceRewriter.UUIDValue {
        .init(lower: UInt64(o.uuidW1) << 32 | UInt64(o.uuidW0), upper: UInt64(o.uuidW3) << 32 | UInt64(o.uuidW2))
    }

    func inFamily(_ u: ReferenceRewriter.UUIDValue) -> Bool {
        families.contains { u.upper == $0.old.upper && u.lower >= $0.old.lower && u.lower - $0.old.lower < $0.span }
    }

    /// The registration for the tables among `copied` (source objects), allocating identifiers for
    /// the engine copies. `strict`: refuse a dependency record naming an owner outside its family.
    static func plan(source: KeynoteDocument, target: KeynoteDocument, copied: Set<UInt64>, keeping: Set<UInt64>, strict: Bool,
                     identifiers: inout [UInt64: UInt64], allocator: inout IDAllocator) throws -> TableRegistration {
        var plan = TableRegistration()
        var names = [ReferenceRewriter.UUIDValue: String]()
        for id in copied.sorted() where source.store.record(for: id)?.info.messageInfos.first?.type == KeynoteDocument.tableModelType {
            guard let model = source.decoded(TST_TableModelArchive.self, id), let old = KeynoteDocument.uuidValue(model.tableID) else { continue }
            let uuid = Foundation.UUID()
            guard let new = KeynoteDocument.uuidValue(uuid.uuidString) else { continue }
            plan.families.append(.init(old: old, new: new, span: KeynoteDocument.ownerFamilySpan))
            plan.tableIDs[id] = uuid.uuidString
            names[old] = model.tableName
        }
        guard !plan.families.isEmpty else { return plan }
        func engine(_ d: KeynoteDocument) -> (UInt64, TSCE_CalculationEngineArchive)? {
            guard let id = d.store.identifiers.first(where: { d.store.record(for: $0)?.info.messageInfos.first?.type == KeynoteDocument.calculationEngineType }),
                  let e = d.decoded(TSCE_CalculationEngineArchive.self, id) else { return nil }
            return (id, e)
        }
        guard let (sourceEngineID, sourceEngine) = engine(source), let (targetEngineID, targetEngine) = engine(target) else {
            throw Failure.noCalculationEngine
        }
        plan.targetEngine = targetEngineID
        let targetMap = targetEngine.dependencyTracker.ownerIDMap
        var next = UInt64((targetMap.mapEntry.map(\.internalOwnerID) + targetMap.unregisteredInternalOwnerID).max() ?? 0) + 1
        for entry in sourceEngine.dependencyTracker.ownerIDMap.mapEntry where plan.inFamily(uuid(entry.ownerID)) {
            guard next <= UInt64(UInt32.max) else { throw KeynoteDocument.SlideCloneFailure.ownerIdentifiersExhausted }
            plan.ownerIDs[UInt64(entry.internalOwnerID)] = next
            plan.mapEntries.append(entry)
            next += 1
        }
        var roots = Set<UInt64>()
        for ref in sourceEngine.dependencyTracker.formulaOwnerDependencies {
            guard let d = source.decoded(TSCE_FormulaOwnerDependenciesArchive.self, ref.identifier) else { continue }
            let owner = ReferenceRewriter.UUIDValue(lower: d.formulaOwnerUid.lower, upper: d.formulaOwnerUid.upper)
            if plan.inFamily(owner) || (d.hasBaseOwnerUid && plan.inFamily(.init(lower: d.baseOwnerUid.lower, upper: d.baseOwnerUid.upper))) {
                roots.insert(ref.identifier)
                plan.dependencies.append(ref.identifier)
            }
        }
        plan.uuidReferences = sourceEngine.uuidReferenceMap.cellRefsForUuid.filter { plan.inFamily(.init(lower: $0.uuid.lower, upper: $0.uuid.upper)) }
        for id in source.heldOnly(by: roots, referrers: source.referrerIndex(), keeping: keeping.union([sourceEngineID])).sorted() where identifiers[id] == nil {
            identifiers[id] = allocator.allocate()
            plan.engineCopies.append(id)
        }
        if strict {
            let probe = ReferenceRewriter(index: try FieldIndex.load(version: TypeRegistry.pinnedVersion), identifiers: [:], ownerIDs: plan.ownerIDs)
            for id in plan.engineCopies {
                guard let record = source.store.record(for: id) else { continue }
                for (i, m) in record.info.messageInfos.enumerated() where m.baseMessageIndex == nil && i < record.payloads.count {
                    guard let type = Schema.messageType(for: m.type) else { continue }
                    if try !probe.ownerIdentifiers(in: record.payloads[i], message: type.protoMessageName).isSubset(of: Set(plan.ownerIDs.keys)) {
                        throw Failure.foreignOwner(table: names.values.sorted().joined(separator: ", "))
                    }
                }
            }
        }
        return plan
    }

    /// Writes the copies into the target engine's component and registers them.
    func apply(to target: inout KeynoteDocument, source: KeynoteDocument, rewriter: ReferenceRewriter, identifiers: [UInt64: UInt64],
               copy: (ArchiveRecord) throws -> ArchiveRecord) throws {
        guard !isEmpty, var engine = target.decoded(TSCE_CalculationEngineArchive.self, targetEngine),
              let home = target.store.entry(for: targetEngine)?.component else { return }
        for id in engineCopies {
            guard let record = source.store.record(for: id) else { continue }
            target.store.append(try copy(record), to: home)
        }
        for id in dependencies {
            engine.dependencyTracker.formulaOwnerDependencies.append(TSP_Reference.with { $0.identifier = identifiers[id]! })
        }
        for entry in mapEntries {
            guard let newInternal = ownerIDs[UInt64(entry.internalOwnerID)], let new = rewriter.mapped(Self.uuid(entry.ownerID)) else { continue }
            engine.dependencyTracker.ownerIDMap.mapEntry.append(.with {
                $0.internalOwnerID = UInt32(truncatingIfNeeded: newInternal)      // ≤ UInt32.max, checked in plan
                $0.ownerID = TSP_CFUUIDArchive.with {
                    $0.uuidW0 = UInt32(truncatingIfNeeded: new.lower); $0.uuidW1 = UInt32(truncatingIfNeeded: new.lower >> 32)
                    $0.uuidW2 = UInt32(truncatingIfNeeded: new.upper); $0.uuidW3 = UInt32(truncatingIfNeeded: new.upper >> 32)
                }
            })
        }
        for refs in uuidReferences {
            let moved = try rewriter.rewrite(try refs.serializedData(partial: true), message: "TSCE.UuidReferenceMapArchive.CellRefsForUuid")
            engine.uuidReferenceMap.cellRefsForUuid.append(try TSCE_UuidReferenceMapArchive.CellRefsForUuid(serializedBytes: moved, partial: true))
        }
        try target.replacePayload(of: targetEngine, with: try engine.serializedData(partial: true))
    }

    /// A copied record's payload with its new table_id, when it is a copied table model.
    func withTableID(_ payload: Data, record: UInt64) throws -> Data {
        guard let tableID = tableIDs[record] else { return payload }
        var model = try TST_TableModelArchive(serializedBytes: payload, extensions: Schema.extensions, partial: true)
        model.tableID = tableID
        return try model.serializedData(partial: true)
    }
}
