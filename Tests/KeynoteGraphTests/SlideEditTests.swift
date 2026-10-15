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
