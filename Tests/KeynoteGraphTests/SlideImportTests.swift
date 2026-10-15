import Foundation
import IWASchema
import Testing
@testable import KeynoteGraph

/// Phase 3b over the corpus: every slide of every template deck imported into a target of the
/// same size (Basic Black), saved, reopened and validated; refusals are counted by reason.
@Suite("Slide import")
struct SlideImportTests {
    @Test("every template slide either imports into Basic Black and validates, or is refused with a typed reason", .enabled(if: FileManager.default.fileExists(atPath: CorpusTests.repoRoot.appendingPathComponent("Corpus/templates/basic-black_wide.key").path), "no Corpus/templates: run `make corpus`"))
    func corpusImport() throws {
        let templates = CorpusTests.repoRoot.appendingPathComponent("Corpus/templates")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var imported = 0, sameTheme = 0
        var refused = [String: Int]()
        var failures = [String]()
        func fail(_ s: String) { if failures.count < 12 { failures.append(s) } }
        for size in ["wide", "standard"] {
            let target = try KeynoteDocument.open(templates.appendingPathComponent("basic-black_\(size).key"))
            let sources = try FileManager.default.contentsOfDirectory(at: templates, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "key" && $0.lastPathComponent.hasSuffix("_\(size).key") }.sorted { $0.path < $1.path }
            for url in sources {
                let source = try KeynoteDocument.open(url)
                for i in try source.slideList().indices {
                    var document = target
                    do {
                        let report = try document.importSlide(at: i, from: source)
                        let out = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(i).key")
                        try document.save(to: out)
                        let reread = try KeynoteDocument.open(out)
                        if let e = reread.validate().first(where: { $0.severity == .error }) { fail("\(url.lastPathComponent) #\(i): \(e)") }
                        if let e = reread.externalReferenceIssue() { fail("\(url.lastPathComponent) #\(i): \(e)") }
                        if try reread.slideList().last?.slide != report.slide { fail("\(url.lastPathComponent) #\(i): not appended") }
                        imported += 1
                        if url.lastPathComponent.hasPrefix("basic-black") { sameTheme += 1 }
                    } catch let failure as KeynoteDocument.SlideImportFailure {
                        let reason: String
                        switch failure {
                        case .unmatchedStyles: reason = "unmatched styles"
                        case .unmatchedMaster: reason = "unmatched master"
                        case .ambiguousMaster: reason = "ambiguous master"
                        case .unsupportedContent: reason = "builds"
                        case .unsupportedReference(let type): reason = "no rule for \(type)"
                        case .noStylesheet, .unplaceable: reason = "\(failure)"
                        }
                        refused[reason, default: 0] += 1
                    } catch let failure as TableRegistration.Failure {
                        refused["\(failure)".hasPrefix("table") ? "cross-table formulas" : "\(failure)", default: 0] += 1
                    } catch {
                        fail("\(url.lastPathComponent) #\(i): \(error)")
                    }
                }
            }
        }
        print("slide import: \(imported) imported (\(sameTheme) from the target's own theme), refused \(refused.sorted { $0.key < $1.key }); \(failures.count) failure(s)")
        failures.forEach { print("  \($0)") }
        #expect(failures.isEmpty)
        #expect(sameTheme > 0)
    }
}
