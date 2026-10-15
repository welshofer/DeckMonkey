import Foundation
import IWASchema
import Testing
@testable import KeynoteGraph

/// Phase 3a over the corpus: move and delete slides in every deck with a flat slide tree; every
/// result saves, reopens, validates (component list, data, references) and has the expected order.
@Suite("Slide move and delete")
struct SlideEditTests {
    @Test("move and delete in every corpus deck: expected order, valid, no orphaned data", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus"))
    func corpusMoveDelete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-slides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var moved = 0, deleted = 0, refusedDecks = 0
        var failures = [String]()
        func fail(_ s: String) { if failures.count < 12 { failures.append(s) } }
        for (n, url) in CorpusTests.corpusFiles().enumerated() {
            guard let original = try? KeynoteDocument.open(url), original.writtenByNewerKeynote == nil else { continue }
            guard let list = try? original.slideList(), list.count >= 2 else { refusedDecks += 1; continue }
            // Move the first slide to the end.
            do {
                var document = original
                try document.moveSlide(from: 0, to: list.count - 1)
                let out = dir.appendingPathComponent("\(n)-move.key")
                try document.save(to: out)
                let reread = try KeynoteDocument.open(out)
                let after = try reread.slideList().map(\.slide)
                if after != Array(list.dropFirst().map(\.slide)) + [list[0].slide] { fail("\(url.lastPathComponent): move order \(after)") }
                if let e = reread.validate().first(where: { $0.severity == .error }) { fail("\(url.lastPathComponent) move: \(e)") }
                if let e = reread.externalReferenceIssue() { fail("\(url.lastPathComponent) move: \(e)") }
                moved += 1
            } catch {
                fail("\(url.lastPathComponent) move: \(error)")
            }
            // Delete the middle slide.
            do {
                var document = original
                let victim = list.count / 2
                do {
                    try document.deleteSlide(at: victim)
                } catch KeynoteDocument.SlideEditFailure.referencedFromOutside {
                    refusedDecks += 1
                    continue
                }
                let out = dir.appendingPathComponent("\(n)-delete.key")
                try document.save(to: out)
                let reread = try KeynoteDocument.open(out)
                let after = try reread.slideList().map(\.slide)
                var expected = list.map(\.slide)
                expected.remove(at: victim)
                if after != expected { fail("\(url.lastPathComponent): delete order") }
                if reread.store.entry(for: list[victim].slide) != nil { fail("\(url.lastPathComponent): the deleted slide is still there") }
                if let e = reread.validate().first(where: { $0.severity == .error }) { fail("\(url.lastPathComponent) delete: \(e)") }
                if let e = reread.externalReferenceIssue() { fail("\(url.lastPathComponent) delete: \(e)") }
                let m = try #require(reread.packageMetadata)
                var referenced = Set<UInt64>()
                for c in reread.store.components { for r in c.records { for i in r.info.messageInfos { referenced.formUnion(i.dataReferences) } } }
                if let orphan = m.datas.first(where: { !referenced.contains($0.identifier) }) { fail("\(url.lastPathComponent): orphaned data \(orphan.identifier)") }
                let described = Set(m.datas.compactMap(\.storedFileName).map { "Data/" + $0 })
                if let extra = reread.package.dataNames.first(where: { !described.contains($0) }) { fail("\(url.lastPathComponent): undescribed \(extra)") }
                deleted += 1
            } catch {
                fail("\(url.lastPathComponent) delete: \(error)")
            }
        }
        print("slides: \(moved) moves and \(deleted) deletes saved and validated; \(refusedDecks) deck(s) refused (tree or outside references); \(failures.count) failure(s)")
        failures.forEach { print("  \($0)") }
        #expect(failures.isEmpty)
        #expect(deleted > 100)
    }

    /// AT-20 shape over the corpus: clone a slide in every deck; the copy shares no identifier with
    /// its source, every UUID stays unique across components, and the deck saves, reopens, validates.
    @Test("clone a slide in every corpus deck: fresh identifiers and UUIDs, valid, nothing orphaned", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus"))
    func corpusClone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-clone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var cloned = 0, refused = 0
        var failures = [String]()
        func fail(_ s: String) { if failures.count < 12 { failures.append(s) } }
        for (n, url) in CorpusTests.corpusFiles().enumerated() {
            guard var document = try? KeynoteDocument.open(url), document.writtenByNewerKeynote == nil,
                  let list = try? document.slideList(), !list.isEmpty else { continue }
            // The first slide the Phase 3a rules accept.
            var report: KeynoteDocument.SlideCloneReport?
            for i in list.indices {
                if let r = try? document.cloneSlide(at: i) { report = r; break }
            }
            guard let report else { refused += 1; continue }
            do {
                let out = dir.appendingPathComponent("\(n).key")
                let sourceIDs = Set(document.store.components.first { $0.name == list.first { $0.slide == report.source }!.component }!.records.map(\.identifier))
                let copyIDs = Set(document.store.components.first { $0.name == report.component }!.records.map(\.identifier))
                if !sourceIDs.isDisjoint(with: copyIDs) { fail("\(url.lastPathComponent): the copy shares identifiers with its source") }
                try document.save(to: out)
                let reread = try KeynoteDocument.open(out)
                if let e = reread.validate().first(where: { $0.severity == .error }) { fail("\(url.lastPathComponent): \(e)") }
                if let e = reread.externalReferenceIssue() { fail("\(url.lastPathComponent): \(e)") }
                let after = try reread.slideList().map(\.slide)
                if after.count != list.count + 1 || !after.contains(report.slide) { fail("\(url.lastPathComponent): slide list") }
                let m = try #require(reread.packageMetadata)
                let uuids = m.components.flatMap(\.objectUuidMapEntries).map { "\($0.uuid.lower):\($0.uuid.upper)" }
                if Set(uuids).count != uuids.count { fail("\(url.lastPathComponent): duplicate UUIDs") }
                if m.lastObjectIdentifier < reread.store.highestIdentifier { fail("\(url.lastPathComponent): last_object_identifier below the store") }
                var referenced = Set<UInt64>()
                for c in reread.store.components { for r in c.records { for i in r.info.messageInfos { referenced.formUnion(i.dataReferences) } } }
                if m.datas.contains(where: { !referenced.contains($0.identifier) }) { fail("\(url.lastPathComponent): orphaned data") }
                cloned += 1
            } catch {
                fail("\(url.lastPathComponent): \(error)")
            }
        }
        print("clone: \(cloned) decks cloned, saved and validated; \(refused) refused; \(failures.count) failure(s)")
        failures.forEach { print("  \($0)") }
        #expect(failures.isEmpty)
        #expect(cloned > 100)
    }

    @Test("refusals: index out of range, the last slide")
    func refusals() throws {
        let url = CorpusTests.repoRoot.appendingPathComponent("Corpus/features/notes-skipped.key")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var document = try KeynoteDocument.open(url)
        #expect(throws: KeynoteDocument.SlideEditFailure.indexOutOfRange(9, count: 5)) { try document.moveSlide(from: 9, to: 0) }
        for _ in 0..<4 { try document.deleteSlide(at: 0) }
        #expect(throws: KeynoteDocument.SlideEditFailure.lastSlide) { try document.deleteSlide(at: 0) }
    }
}

@Suite("Calculation engine on slide delete")
struct CalcEngineDeleteTests {
    @Test("a UUID string maps to Keynote's (lower, upper) pair")
    func uuidValue() {
        let v = KeynoteDocument.uuidValue("9918D8F8-C872-4CB9-92DF-48F04DA4962A")
        #expect(v == .init(lower: 0xB94C72C8F8D81899, upper: 0x2A96A44DF048DF92))
        #expect(KeynoteDocument.uuidValue("not a uuid") == nil)
    }

    /// tables.key slide 0 holds a table with formulas; Keynote's re-save of the deleted deck keeps
    /// no owner of that table: no dependency record, owner-map entry or UUID-map entry.
    @Test("deleting a table's slide removes the table's whole formula-owner family", .enabled(if: FileManager.default.fileExists(atPath: CorpusTests.repoRoot.appendingPathComponent("Corpus/features/tables.key").path), "no Corpus/features: run `make corpus`"))
    func tableOwnerFamily() throws {
        var document = try KeynoteDocument.open(CorpusTests.repoRoot.appendingPathComponent("Corpus/features/tables.key"))
        let slide = try document.slideList()[0]
        #expect(document.store.records(in: slide.component)?.isEmpty == false)
        var bases = Set<ReferenceRewriter.UUIDValue>()
        for id in document.store.identifiers where document.store.record(for: id)?.info.messageInfos.first?.type == 6001 {
            if let m = document.decoded(TST_TableModelArchive.self, id), let u = KeynoteDocument.uuidValue(m.tableID) { bases.insert(u) }
        }
        try document.deleteSlide(at: 0)
        var remaining = Set<ReferenceRewriter.UUIDValue>()
        for id in document.store.identifiers where document.store.record(for: id)?.info.messageInfos.first?.type == 6001 {
            if let m = document.decoded(TST_TableModelArchive.self, id), let u = KeynoteDocument.uuidValue(m.tableID) { remaining.insert(u) }
        }
        let deleted = bases.subtracting(remaining)
        #expect(!deleted.isEmpty, "slide 0 of tables.key holds a table")
        func family(_ lower: UInt64, _ upper: UInt64) -> Bool { deleted.contains { $0.upper == upper && lower >= $0.lower && lower - $0.lower < 0x100 } }
        let engineID = try #require(document.store.identifiers.first { document.store.record(for: $0)?.info.messageInfos.first?.type == 4000 })
        let engine = try #require(document.decoded(TSCE_CalculationEngineArchive.self, engineID))
        for ref in engine.dependencyTracker.formulaOwnerDependencies {
            let d = try #require(document.decoded(TSCE_FormulaOwnerDependenciesArchive.self, ref.identifier))
            #expect(!family(d.formulaOwnerUid.lower, d.formulaOwnerUid.upper) && !(d.hasBaseOwnerUid && family(d.baseOwnerUid.lower, d.baseOwnerUid.upper)), "dependency record \(ref.identifier) belongs to the deleted table")
        }
        for e in engine.dependencyTracker.ownerIDMap.mapEntry {
            let o = e.ownerID
            #expect(!family(UInt64(o.uuidW1) << 32 | UInt64(o.uuidW0), UInt64(o.uuidW3) << 32 | UInt64(o.uuidW2)), "owner map entry \(e.internalOwnerID)")
        }
        #expect(!engine.uuidReferenceMap.cellRefsForUuid.contains { family($0.uuid.lower, $0.uuid.upper) })
        #expect(document.validate().filter { $0.severity == .error }.isEmpty)
    }
}

@Suite("Table clone")
struct TableCloneTests {
    /// Every slide with a table, in every corpus deck: the clone saves and validates, its tables
    /// have new table_ids, and each new family has as many owner-map entries and dependency
    /// records as its source family.
    @Test("every table slide clones with its own registered formula-owner family", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus"))
    func corpusTableClone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-tclone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var cloned = 0, refused = 0
        var failures = [String]()
        func fail(_ s: String) { if failures.count < 12 { failures.append(s) } }
        func tables(_ d: KeynoteDocument) -> [String: ReferenceRewriter.UUIDValue] {
            var out = [String: ReferenceRewriter.UUIDValue]()
            for id in d.store.identifiers where d.store.record(for: id)?.info.messageInfos.first?.type == 6001 {
                if let m = d.decoded(TST_TableModelArchive.self, id), let u = KeynoteDocument.uuidValue(m.tableID) { out[m.tableID] = u }
            }
            return out
        }
        func family(_ d: KeynoteDocument, _ base: ReferenceRewriter.UUIDValue) -> (map: Int, dependencies: Int) {
            guard let engineID = d.store.identifiers.first(where: { d.store.record(for: $0)?.info.messageInfos.first?.type == 4000 }),
                  let e = d.decoded(TSCE_CalculationEngineArchive.self, engineID) else { return (0, 0) }
            func near(_ lower: UInt64, _ upper: UInt64) -> Bool { upper == base.upper && lower >= base.lower && lower - base.lower < 0x100 }
            let map = e.dependencyTracker.ownerIDMap.mapEntry.filter { near(UInt64($0.ownerID.uuidW1) << 32 | UInt64($0.ownerID.uuidW0), UInt64($0.ownerID.uuidW3) << 32 | UInt64($0.ownerID.uuidW2)) }.count
            let deps = e.dependencyTracker.formulaOwnerDependencies.filter { ref in
                guard let dep = d.decoded(TSCE_FormulaOwnerDependenciesArchive.self, ref.identifier) else { return false }
                return near(dep.formulaOwnerUid.lower, dep.formulaOwnerUid.upper) || (dep.hasBaseOwnerUid && near(dep.baseOwnerUid.lower, dep.baseOwnerUid.upper))
            }.count
            return (map, deps)
        }
        for (n, url) in CorpusTests.corpusFiles().enumerated() {
            guard let original = try? KeynoteDocument.open(url), original.writtenByNewerKeynote == nil,
                  let list = try? original.slideList() else { continue }
            let before = tables(original)
            guard !before.isEmpty else { continue }
            for i in list.indices {
                var document = original
                guard (try? document.cloneSlide(at: i)) != nil else { refused += 1; continue }
                let added = tables(document).filter { before[$0.key] == nil }
                guard !added.isEmpty else { continue }                // this slide holds no table
                do {
                    let out = dir.appendingPathComponent("\(n)-\(i).key")
                    try document.save(to: out)
                    let reread = try KeynoteDocument.open(out)
                    if let e = reread.validate().first(where: { $0.severity == .error }) { fail("\(url.lastPathComponent) #\(i): \(e)") }
                    if let e = reread.externalReferenceIssue() { fail("\(url.lastPathComponent) #\(i): \(e)") }
                    let sources = before.values.map { family(original, $0) }.filter { $0.map > 0 }
                    for (id, base) in added {
                        let f = family(reread, base)
                        if f.map == 0 || !sources.contains(where: { $0 == f }) { fail("\(url.lastPathComponent) #\(i): table \(id) registers \(f), sources \(sources)") }
                    }
                    cloned += 1
                } catch {
                    fail("\(url.lastPathComponent) #\(i): \(error)")
                }
            }
        }
        print("table clone: \(cloned) table slides cloned, saved and validated; \(refused) slides refused; \(failures.count) failure(s)")
        failures.forEach { print("  \($0)") }
        #expect(cloned > 0)
        #expect(failures.isEmpty)
    }
}

extension KeynoteDocument {
    /// Nil when every component's `external_references` holds each reference the rule derives and
    /// nothing whose target is gone.
    func externalReferenceIssue() -> String? {
        guard let metadata = packageMetadata, let strength = try? ReferenceStrength.load(version: TypeRegistry.pinnedVersion) else { return "no metadata" }
        let ids = componentIdentifiers(metadata)
        let names = Set(ids.values)
        for c in metadata.components {
            let name = "Index/\(c.locator.isEmpty ? c.preferredLocator : c.locator).iwa"
            let stored = Set(c.externalReferences.map { [$0.componentIdentifier, $0.objectIdentifier] })
            let derived = derivedExternalReferences(of: name, componentIDs: ids, strength: strength)
            if let missing = derived.first(where: { !stored.contains([$0.component, $0.object]) }) {
                return "\(name) lacks external reference \(missing.component)/\(missing.object)"
            }
            if c.externalReferences.contains(where: { $0.hasObjectIdentifier && $0.objectIdentifier == 0 }) {
                return "\(name) has an external reference with an explicit object identifier 0"
            }
            if let gone = c.externalReferences.first(where: { !names.contains($0.componentIdentifier) || ($0.objectIdentifier != 0 && store.entry(for: $0.objectIdentifier) == nil) }) {
                return "\(name) keeps external reference \(gone.componentIdentifier)/\(gone.objectIdentifier) to nothing"
            }
        }
        return nil
    }
}
