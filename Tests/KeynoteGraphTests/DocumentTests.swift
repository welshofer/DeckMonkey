import Foundation
import IWAArchive
import IWAContainer
import IWASnappy
import Testing
@testable import KeynoteGraph

/// A synthetic Keynote-shaped package: two components, a few records, one merge.
enum SynthDocument {
    static func record(id: UInt64, type: UInt32, payload: [UInt8], refs: [UInt64] = []) -> ArchiveRecord {
        var info = MessageInfo(type: type, version: [2, 0, 0], length: UInt32(payload.count))
        info.setObjectReferences(refs)
        return ArchiveRecord(info: ArchiveInfo(identifier: id, messageInfos: [info]), payloads: [Data(payload)])
    }

    static func package() throws -> IWAPackage {
        let document = ArchiveStream.join([
            record(id: 1, type: 1, payload: [UInt8](repeating: 7, count: 500), refs: [2, 10_000]),
            record(id: 2, type: 2, payload: [1, 2, 3]),
        ])
        let slide = ArchiveStream.join([
            record(id: 10_000, type: 10_000, payload: [UInt8]("slide one".utf8), refs: [10_001]),
            record(id: 10_001, type: 10_001, payload: [UInt8]("drawable".utf8)),
        ])
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><array><string>M15.4-7051-1</string></array></plist>
            """
        return IWAPackage(form: .zip, entries: [
            "Index/Document.iwa": try IWAChunking.compress(document),
            "Index/Slide-10000.iwa": try IWAChunking.compress(slide),
            "Metadata/BuildVersionHistory.plist": Data(plist.utf8),
            "Data/image-1.jpg": Data([0xFF, 0xD8]),
        ])
    }
}

@Suite("KeynoteDocument")
struct DocumentTests {
    @Test("opens a synthetic package into the store and summarizes it")
    func openAndSummarize() throws {
        let document = try KeynoteDocument.open(try SynthDocument.package())
        let s = document.summary
        #expect(s.components == ["Index/Document.iwa", "Index/Slide-10000.iwa"])
        #expect(s.objectCount == 4)
        #expect(s.recordCount == 4)
        #expect(s.mergeRecordCount == 0)
        #expect(s.highestIdentifier == 10_001)
        #expect(s.typeHistogram == [1: 1, 2: 1, 10_000: 1, 10_001: 1])
        #expect(s.buildVersionHistory == ["M15.4-7051-1"])
        #expect(s.dataEntries == 1)
        #expect(document.lastSavedBy == "M15.4-7051-1")
        #expect(document.validate().isEmpty)
        var allocator = document.makeIDAllocator()
        #expect(allocator.allocate() == 10_002)
        #expect(allocator.allocate() == 10_003)
        #expect(allocator.highWaterMark == 10_003)
    }

    @Test("AT-09 shape: open→save→open leaves every component byte-identical after decompression")
    func roundTrip() throws {
        let document = try KeynoteDocument.open(try SynthDocument.package())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.key")
        try document.save(to: out)
        let reread = try KeynoteDocument.open(out)
        let a = document.store.joinedComponents()
        let b = reread.store.joinedComponents()
        #expect(a.map(\.name) == b.map(\.name))
        for (x, y) in zip(a, b) {
            #expect(x.decompressed == y.decompressed, "\(x.name)")
        }
        #expect(reread.package.data("Data/image-1.jpg") == Data([0xFF, 0xD8]))
        #expect(reread.package.buildVersionHistory == ["M15.4-7051-1"])
    }

    @Test("a dangling header reference is reported (warning until AT-06 promotes it)")
    func danglingReference() throws {
        var package = try SynthDocument.package()
        let broken = ArchiveStream.join([SynthDocument.record(id: 1, type: 1, payload: [0], refs: [424_242])])
        package.set("Index/Document.iwa", try IWAChunking.compress(broken))
        let document = try KeynoteDocument.open(package)
        let issues = document.validate()
        #expect(issues.contains { $0.kind == .danglingObjectReference(from: 1, to: 424_242) })
    }

    @Test("AT-26 shape: a duplicate identifier blocks save")
    func duplicateBlocksSave() throws {
        var package = try SynthDocument.package()
        let dup = ArchiveStream.join([SynthDocument.record(id: 10_000, type: 5, payload: [0])])
        package.set("Index/Extra.iwa", try IWAChunking.compress(dup))
        let document = try KeynoteDocument.open(package)
        #expect(document.validate().contains { $0.severity == .error })
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-dup-\(UUID().uuidString).key")
        #expect(throws: KeynoteError.self) { try document.save(to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}

/// Runs the round-trip gate over every `.key` the environment points at. Private decks stay out
/// of the repo: set `DECKMONKEY_CORPUS=/path/to/decks`, or put that path in a git-ignored
/// `.deckmonkey-corpus` file at the repo root. Both are scanned recursively, as is the in-repo
/// `Corpus/` once synthetic decks land there.
@Suite("Corpus round-trip")
struct CorpusTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func corpusRoots() -> [URL] {
        var roots = [URL]()
        if let env = ProcessInfo.processInfo.environment["DECKMONKEY_CORPUS"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env))
        } else if let pointer = try? String(contentsOf: repoRoot.appendingPathComponent(".deckmonkey-corpus"), encoding: .utf8),
                  let line = pointer.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
                  !line.isEmpty {
            roots.append(URL(fileURLWithPath: (line as NSString).expandingTildeInPath))
        }
        roots.append(repoRoot.appendingPathComponent("Corpus"))
        return roots
    }

    static func corpusFiles() -> [URL] {
        var files = [URL]()
        for root in corpusRoots() {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "key" {
                files.append(url)
                enumerator.skipDescendants()   // a .key may itself be a package directory
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    @Test("AT-09: every corpus file opens, validates, and round-trips clean", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus: set DECKMONKEY_CORPUS, write .deckmonkey-corpus, or add decks under Corpus/"))
    func corpusRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = Self.corpusFiles()
        var clean = 0
        print("corpus: \(files.count) deck(s) under \(Self.corpusRoots().map(\.path).joined(separator: ", "))")
        for file in files {
            let name = file.lastPathComponent
            let document: KeynoteDocument
            do {
                document = try KeynoteDocument.open(file)
            } catch {
                Issue.record("\(name): open failed: \(error)")
                continue
            }
            let s = document.summary
            let issues = document.validate()
            let errors = issues.filter { $0.severity == .error }
            print("  \(name): form=\(document.package.form) nested=\(document.package.nestedIndex) components=\(s.components.count) objects=\(s.objectCount) merges=\(s.mergeRecordCount) maxID=\(s.highestIdentifier) types=\(s.typeHistogram.count) data=\(s.dataEntries) saved-by=\(s.buildVersionHistory.last ?? "-") issues=\(issues.count)")
            #expect(errors.isEmpty, "\(name): \(errors)")
            let out = dir.appendingPathComponent(name)
            do {
                try document.save(to: out)
            } catch {
                Issue.record("\(name): save failed: \(error)")
                continue
            }
            let reread: KeynoteDocument
            do {
                reread = try KeynoteDocument.open(out)
            } catch {
                Issue.record("\(name): re-open of saved output failed: \(error)")
                continue
            }
            let a = document.store.joinedComponents()
            let b = reread.store.joinedComponents()
            var identical = a.count == b.count
            for (x, y) in zip(a, b) where x.decompressed != y.decompressed {
                identical = false
                Issue.record("\(name): \(x.name) differs after round-trip")
            }
            if identical { clean += 1 }
        }
        print("corpus roundtrip CLEAN \(clean)/\(files.count)")
        #expect(clean == files.count)
    }
}
