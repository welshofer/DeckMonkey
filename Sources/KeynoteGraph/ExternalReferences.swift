import Foundation
import IWAArchive
import IWASchema

/// `PackageMetadata.components[].external_references`: per component, the objects in *other*
/// components that its objects reference. Learned from the decks Keynote 15.4 alone saved
/// (`CorpusTests.corpusExternalReferences`), the rule is
///
/// - one entry per (target component, target object) referenced from any payload of the component;
/// - a reference to a component's root object (object identifier == component identifier) is
///   stored with no object identifier (absent, never an explicit 0: Keynote calls such a file
///   damaged);
/// - `is_weak` is set (to true) only when every reference to that object is through a weak field;
///   a single strong reference makes the entry strong.
///
/// Keynote also keeps a few entries no payload holds any more (stale weak entries to objects that
/// still exist); those are preserved, as everything else not understood is (invariant 2).
public struct ExternalReference: Hashable, Sendable, Comparable {
    public var component: UInt64
    public var object: UInt64
    public var isWeak: Bool

    public static func < (a: ExternalReference, b: ExternalReference) -> Bool {
        (a.component, a.object) < (b.component, b.object)
    }
}

extension KeynoteDocument {
    /// The component identifier for each component file name (`Index/<locator>.iwa`).
    func componentIdentifiers(_ metadata: TSP_PackageMetadata) -> [String: UInt64] {
        var out = [String: UInt64]()
        for c in metadata.components {
            out["Index/\(c.locator.isEmpty ? c.preferredLocator : c.locator).iwa"] = c.identifier
        }
        return out
    }

    /// The external references the rule derives for the component file `name`, sorted.
    func derivedExternalReferences(of name: String, componentIDs: [String: UInt64], strength: ReferenceStrength) -> [ExternalReference] {
        guard let here = componentIDs[name], let records = store.records(in: name) else { return [] }
        var weakOnly = [UInt64: [UInt64: Bool]]()       // component → object → every reference weak
        for record in records {
            for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil {
                guard let derived = try? ReferenceDerivation.derive(type: info.type, payload: record.payloads[i]) else { continue }
                for (ref, field) in zip(derived.objects, derived.objectFields) {
                    guard let entry = store.entry(for: ref), let there = componentIDs[entry.component], there != here else { continue }
                    let object = ref == there ? 0 : ref
                    let weak = strength.strength(of: field) == .weak
                    weakOnly[there, default: [:]][object] = (weakOnly[there]?[object] ?? true) && weak
                }
            }
        }
        return weakOnly.flatMap { component, objects in
            objects.map { ExternalReference(component: component, object: $0.key, isWeak: $0.value) }
        }.sorted()
    }

    /// Rebuilds `external_references` for every component holding a changed (dirty) record; the
    /// lists of untouched components stay as Keynote wrote them. An entry the payloads no longer
    /// justify is kept only while its target still exists (Keynote's own stale entries survive; one
    /// to a deleted object does not). Kept entries keep their order; new ones follow, sorted.
    mutating func refreshExternalReferences() throws {
        let dirty = Set(store.components.filter { $0.records.contains(where: \.isDirty) }.map(\.name))
        guard !dirty.isEmpty, var metadata = packageMetadata else { return }
        let strength = try ReferenceStrength.load(version: TypeRegistry.pinnedVersion)
        let ids = componentIdentifiers(metadata)
        let nameOf = Dictionary(ids.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let before = metadata
        for c in metadata.components.indices {
            let locator = metadata.components[c].locator.isEmpty ? metadata.components[c].preferredLocator : metadata.components[c].locator
            let name = "Index/\(locator).iwa"
            guard dirty.contains(name) else { continue }
            let derived = derivedExternalReferences(of: name, componentIDs: ids, strength: strength)
            var byTarget = Dictionary(derived.map { ([$0.component, $0.object], $0) }, uniquingKeysWith: { a, _ in a })
            func exists(_ e: TSP_ComponentExternalReference) -> Bool {
                guard let target = nameOf[e.componentIdentifier] else { return false }
                return e.objectIdentifier == 0 || store.entry(for: e.objectIdentifier)?.component == target
            }
            var kept = [TSP_ComponentExternalReference]()
            for var e in metadata.components[c].externalReferences {
                if let rule = byTarget.removeValue(forKey: [e.componentIdentifier, e.objectIdentifier]) {
                    if rule.isWeak { e.isWeak = true } else { e.clearIsWeak() }
                    kept.append(e)
                } else if exists(e) {
                    kept.append(e)
                }
            }
            for rule in byTarget.values.sorted() {
                kept.append(TSP_ComponentExternalReference.with {
                    $0.componentIdentifier = rule.component
                    if rule.object != 0 { $0.objectIdentifier = rule.object }
                    if rule.isWeak { $0.isWeak = true }
                })
            }
            metadata.components[c].externalReferences = kept
        }
        if metadata != before { try replacePayload(of: 2, with: try metadata.serializedData(partial: true)) }
    }
}
