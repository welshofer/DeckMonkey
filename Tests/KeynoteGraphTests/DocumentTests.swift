import Foundation
import IWAArchive
import IWAContainer
import IWASnappy
import IWASchema
import SwiftProtobuf
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
            record(id: 10_000, type: 5, payload: [UInt8]("slide one".utf8), refs: [10_001]),      // KN.SlideArchive
            record(id: 10_001, type: 2001, payload: [UInt8]("drawable".utf8)),                     // TSWP.StorageArchive
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
        #expect(s.typeHistogram == [1: 1, 2: 1, 5: 1, 2001: 1])
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

    @Test("a dangling header reference is an error and blocks save (invariant 8)")
    func danglingReference() throws {
        var package = try SynthDocument.package()
        let broken = ArchiveStream.join([SynthDocument.record(id: 1, type: 1, payload: [0], refs: [424_242])])
        package.set("Index/Document.iwa", try IWAChunking.compress(broken))
        let document = try KeynoteDocument.open(package)
        let issues = document.validate()
        #expect(issues.contains { $0.kind == .danglingObjectReference(from: 1, to: 424_242) && $0.severity == .error })
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-dangling-\(UUID().uuidString).key")
        #expect(throws: KeynoteError.self) { try document.save(to: out) }
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

    @Test("invariant 8: an unknown type blocks save; a merge diff descriptor and a deprecated type do not")
    func unknownTypeIsAnError() throws {
        var package = try SynthDocument.package()
        // A merge archive as Keynote writes one: [0] a payload, [1] the diff descriptor (type 0,
        // base_message_index 0, sentinel version). And type 6219, which 15.4 declares deprecated.
        var payload = MessageInfo(type: 2001, version: [1, 0, 5], length: 1)
        payload.setObjectReferences([])
        let diff = try MessageInfo(fields: [
            WireField(number: MessageInfo.typeField, value: .varint(0)),
            WireField(number: MessageInfo.versionField, value: Wire.packed([65535, 65535, 4_294_967_295])),
            WireField(number: MessageInfo.lengthField, value: .varint(1)),
            WireField(number: MessageInfo.baseMessageIndexField, value: .varint(0)),
        ], messageIndex: 1)
        // Fresh headers are never merge records (writes consolidate), so this one is read the way
        // Keynote's arrive: encoded, should_merge = 1 appended (field 3, varint), decoded.
        let header = ArchiveInfo(identifier: 20_000, messageInfos: [payload, diff]).encoded() + [0x18, 0x01]
        let merge = ArchiveRecord(info: try ArchiveInfo(bytes: header), payloads: [Data([0x08]), Data([0x08])])
        #expect(merge.shouldMerge)
        let deprecated = SynthDocument.record(id: 20_001, type: 6219, payload: [0])
        package.set("Index/Extra.iwa", try IWAChunking.compress(ArchiveStream.join([merge, deprecated])))
        #expect(try KeynoteDocument.open(package).validate().isEmpty)

        package.set("Index/Unknown.iwa", try IWAChunking.compress(ArchiveStream.join([SynthDocument.record(id: 20_002, type: 999_999, payload: [0])])))
        let document = try KeynoteDocument.open(package)
        #expect(document.validate() == [ValidationIssue(severity: .error, kind: .unknownType(999_999, identifier: 20_002))])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-unknown-\(UUID().uuidString).key")
        #expect(throws: KeynoteError.self) { try document.save(to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test("reference derivation: every TSP.Reference and TSP.DataReference in a decoded payload, in traversal order")
    func deriveReferences() throws {
        // KN.SlideNodeArchive (type 4): children and slide are references, thumbnails data refs.
        var node = KN_SlideNodeArchive()
        node.isSkipped = false
        node.hasBuilds_p = false       // protoc-gen-swift escapes has-prefixed field names
        node.hasTransition_p = false
        node.children = [TSP_Reference.with { $0.identifier = 30 }, TSP_Reference.with { $0.identifier = 31 }]
        node.slide = TSP_Reference.with { $0.identifier = 40 }
        node.thumbnails = [TSP_DataReference.with { $0.identifier = 7 }, TSP_DataReference.with { $0.identifier = 7 }]
        let derived = try ReferenceDerivation.derive(type: 4, payload: try node.serializedData())
        #expect(derived.objects == [30, 31, 40])
        #expect(derived.objectFields == ["KN.SlideNodeArchive.1", "KN.SlideNodeArchive.1", "KN.SlideNodeArchive.2"])
        #expect(derived.data == [7, 7])
        #expect(!derived.hasUnknownFields)

        #expect(throws: ReferenceDerivation.Failure.noMessage(type: 6219)) {
            try ReferenceDerivation.derive(type: 6219, payload: Data())
        }
        #expect(throws: ReferenceDerivation.Failure.self) {
            try ReferenceDerivation.derive(type: 4, payload: Data([0x0A, 0x05, 0x08]))   // truncated child
        }
    }

    @Test("invariant 4: strong fields list, weak fields don't, mixed fields keep stored membership, unseen fields refuse")
    func listingRule() throws {
        let strength = ReferenceStrength(keynoteVersion: "test", fields: ["A.1": .strong, "A.2": .weak, "A.3": .mixed])
        func refs(_ pairs: [(UInt64, String)]) -> DerivedReferences {
            DerivedReferences(objects: pairs.map(\.0), objectFields: pairs.map(\.1))
        }
        // 10 strong; 20 only weak; 30 weak here but strong there: listed once.
        #expect(try ReferenceDerivation.listedObjects(refs([(10, "A.1"), (20, "A.2"), (30, "A.2"), (30, "A.1")]), strength: strength) == [10, 30])
        // Mixed: 40 was held and listed, 41 held and unlisted, 42 is new (listed: a missing strong edge loses objects).
        let original = refs([(40, "A.3"), (41, "A.3")])
        let edited = refs([(40, "A.3"), (41, "A.3"), (42, "A.3")])
        #expect(try ReferenceDerivation.listedObjects(edited, strength: strength, original: (original, [40])) == [40, 42])
        #expect(throws: ReferenceDerivation.ListingFailure.unclassifiedField("B.9")) {
            try ReferenceDerivation.listedObjects(refs([(50, "B.9")]), strength: strength)
        }
    }

    @Test("the learner: unlisted proves not-strong; listings explained by a strong twin make a field weak, not mixed")
    func strengthLearner() throws {
        var learner = ReferenceStrengthLearner()
        learner.observeDeck()
        // S.1 always listed; W.1 lists 7 only because S.1 also holds 7; M.1 lists 9 on its own.
        learner.observe(DerivedReferences(objects: [7, 7, 8], objectFields: ["S.1", "W.1", "W.1"]), stored: [7])
        learner.observe(DerivedReferences(objects: [9, 10], objectFields: ["M.1", "M.1"]), stored: [9])
        let file = learner.result(source: "test")
        #expect(file.fields.mapValues(\.strength) == ["S.1": .strong, "W.1": .weak, "M.1": .mixed])
        #expect(file.fields["W.1"] == .init(strength: .weak, occurrences: 2, unlisted: 1, unexplainedListed: 0))
        #expect(file.decks == 1 && file.payloads == 2)
        #expect(try ReferenceStrength.load(from: file.encoded()).fields == file.fields.mapValues(\.strength))
    }

    // First CLI contact: a truncated deck printed only `error: truncated(at: 4)`.
    @Test("a truncated .iwa names its component and the decompress stage")
    func truncatedComponentIsNamed() throws {
        var package = try SynthDocument.package()
        let slide = package.data("Index/Slide-10000.iwa")!
        package.set("Index/Slide-10000.iwa", slide.prefix(slide.count / 2))
        let error = #expect(throws: KeynoteError.self) { try KeynoteDocument.open(package) }
        #expect(error.map { "\($0)" }?.hasPrefix("Index/Slide-10000.iwa: decompress failed: ") == true)
        guard case .componentUnreadable("Index/Slide-10000.iwa", .decompress, let detail)? = error else {
            Issue.record("unexpected error: \(String(describing: error))")
            return
        }
        #expect(detail.contains("past the end"))
    }

    @Test("a well-framed stream with a bad record names its component and the split stage")
    func badRecordIsNamed() throws {
        var package = try SynthDocument.package()
        // ArchiveInfo length 100 with only 2 bytes after it.
        package.set("Index/Slide-10000.iwa", try IWAChunking.compress(Data([100, 0x08, 0x01])))
        let error = #expect(throws: KeynoteError.self) { try KeynoteDocument.open(package) }
        guard case .componentUnreadable("Index/Slide-10000.iwa", .split, _)? = error else {
            Issue.record("unexpected error: \(String(describing: error))")
            return
        }
    }

    @Test("legacy and missing files say so in words, not enum dumps")
    func packageErrorsReadAsText() {
        #expect("\(IWAPackageError.unsupportedLegacyFormat("Old.key"))".contains("Keynote '09"))
        #expect("\(IWAPackageError.notFound("/x.key"))" == "no such file: /x.key")
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

    @Test("AT-05: every type number in every corpus file resolves in the pinned registry (a message, or declared deprecated)", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus: set DECKMONKEY_CORPUS, write .deckmonkey-corpus, or add decks under Corpus/"))
    func corpusTypesResolve() throws {
        var seen = [UInt32: Int]()
        var unresolved = Set<UInt32>()
        var deprecated = Set<UInt32>()
        var decks = 0
        for url in CorpusTests.corpusFiles() {
            guard let document = try? KeynoteDocument.open(url) else { continue }   // legacy decks: AT-09 reports them
            let registry = try #require(document.registry, "the pinned registry did not load")
            decks += 1
            for (type, count) in document.store.typeHistogram {
                seen[type, default: 0] += count
                if !registry.resolves(type) { unresolved.insert(type) }
                if registry.deprecatedTypes.contains(type) { deprecated.insert(type) }
            }
        }
        print("AT-05: \(seen.count) distinct types in \(decks) deck(s): \(seen.count - deprecated.count - unresolved.count) with a message, "
            + "\(deprecated.count) declared deprecated (\(deprecated.sorted().map(String.init).joined(separator: ", "))), \(unresolved.count) unresolved"
            + unresolved.sorted().map { "\n      type \($0) ×\(seen[$0]!)" }.joined())
        #expect(unresolved.isEmpty)
    }

    /// AT-06/07/08 on the corpus (28 decks, 54,348 typed payloads), against the strength table
    /// learned by `make reference-strength` (Registry/reference-strength-15.4.json):
    /// - AT-07: the strong-reference rule reproduces every stored object_references set exactly;
    ///   a reference field the table has never seen fails the test;
    /// - AT-08: data_references are exactly the derived DataReference ids minus 0 (null sentinel);
    /// - AT-06: every strong reference resolves; weak ones may dangle (807 do, in Keynote's files).
    @Test("AT-06/07/08: strong references reproduce Keynote's stored lists", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus: set DECKMONKEY_CORPUS, write .deckmonkey-corpus, or add decks under Corpus/"))
    func corpusReferences() throws {
        let strength = try ReferenceStrength.load(version: TypeRegistry.pinnedVersion)
        var payloads = 0, deprecated = 0, danglingWeak = 0, viaMixed = 0
        var failures = [String]()
        func fail(_ message: String) { if failures.count < 20 { failures.append(message) } }
        for url in CorpusTests.corpusFiles() {
            guard let document = try? KeynoteDocument.open(url) else { continue }
            for component in document.store.components {
                for record in component.records {
                    for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil {
                        let label = "\(url.lastPathComponent) object \(record.identifier) type \(info.type)"
                        let derived: DerivedReferences
                        do {
                            derived = try ReferenceDerivation.derive(type: info.type, payload: record.payloads[i])
                        } catch .noMessage {
                            deprecated += 1
                            continue
                        } catch {
                            fail("\(label): \(error)")
                            continue
                        }
                        payloads += 1
                        if derived.hasUnknownFields { fail("\(label): unknown fields under the pinned schema") }
                        // AT-08
                        if Set(info.dataReferences) != Set(derived.data).subtracting([0]) {
                            fail("\(label): data_references \(info.dataReferences), derived \(derived.data)")
                        }
                        // AT-07
                        let stored = Set(info.objectReferences)
                        do {
                            let listed = try ReferenceDerivation.listedObjects(derived, strength: strength, original: (derived, info.objectReferences))
                            if listed != stored {
                                fail("\(label): rule lists \(listed.subtracting(stored).sorted()) extra, \(stored.subtracting(listed).sorted()) missing")
                            }
                        } catch {
                            fail("\(label): \(error)")
                        }
                        viaMixed += zip(derived.objects, derived.objectFields).filter { strength.strength(of: $0.1) == .mixed }.count
                        // AT-06
                        for (ref, field) in zip(derived.objects, derived.objectFields) where document.store.entry(for: ref) == nil {
                            if strength.strength(of: field) == .weak && !stored.contains(ref) { danglingWeak += 1 } else { fail("\(label): \(field) reference \(ref) is dangling") }
                        }
                    }
                }
            }
        }
        print("references: \(payloads) typed payloads (+\(deprecated) deprecated-type) reproduce their stored lists; "
            + "\(viaMixed) occurrences in mixed fields kept their stored membership; \(danglingWeak) dangling weak references")
        failures.forEach { print("  FAIL \($0)") }
        #expect(failures.isEmpty)
    }

    @Test("AT-09: every corpus file opens, validates, and round-trips clean", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus: set DECKMONKEY_CORPUS, write .deckmonkey-corpus, or add decks under Corpus/"))
    func corpusRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = Self.corpusFiles()
        var clean = 0
        var legacy = 0
        // The report also goes to .build/corpus-report.txt, rewritten after every deck, so a crash
        // mid-corpus still leaves a record of how far it got and what each deck looked like.
        let reportURL = Self.repoRoot.appendingPathComponent(".build/corpus-report.txt")
        var report = ["corpus: \(files.count) deck(s) under \(Self.corpusRoots().map(\.path).joined(separator: ", "))"]
        func log(_ line: String) {
            print(line)
            report.append(line)
            try? report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        }
        log(report[0])
        for file in files {
            let name = file.lastPathComponent
            let document: KeynoteDocument
            do {
                document = try KeynoteDocument.open(file)
            } catch IWAPackageError.unsupportedLegacyFormat {
                // Keynote '09 APXL: out of scope (docs/spec.md §2), counted, never a failure.
                log("  \(name): legacy Keynote '09 format, skipped")
                legacy += 1
                continue
            } catch {
                log("  \(name): OPEN FAILED: \(error)")
                Issue.record("\(name): open failed: \(error)")
                continue
            }
            let s = document.summary
            let issues = document.validate()
            let errors = issues.filter { $0.severity == .error }
            log("  \(name): form=\(document.package.form) nested=\(document.package.nestedIndex) components=\(s.components.count) objects=\(s.objectCount) merges=\(s.mergeRecordCount) mergeOnly=\(s.mergeOnlyObjectCount) maxID=\(s.highestIdentifier) types=\(s.typeHistogram.count) data=\(s.dataEntries) saved-by=\(s.buildVersionHistory.last ?? "-") issues=\(issues.count)")
            if !issues.isEmpty {
                var kinds = [String: Int]()
                for issue in issues {
                    let kind: String
                    switch issue.kind {
                    case .duplicateIdentifier: kind = "duplicateIdentifier"
                    case .danglingObjectReference: kind = "danglingObjectReference"
                    case .unknownType: kind = "unknownType"
                    case .missingDataFile: kind = "missingDataFile"
                    }
                    kinds[kind, default: 0] += 1
                }
                log("      issue kinds: \(kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                for issue in issues.prefix(3) { log("      e.g. \(issue)") }
            }
            #expect(errors.isEmpty, "\(name): \(errors)")
            let out = dir.appendingPathComponent(name)
            do {
                try document.save(to: out)
            } catch {
                log("      SAVE FAILED: \(error)")
                Issue.record("\(name): save failed: \(error)")
                continue
            }
            let reread: KeynoteDocument
            do {
                reread = try KeynoteDocument.open(out)
            } catch {
                log("      RE-OPEN FAILED: \(error)")
                Issue.record("\(name): re-open of saved output failed: \(error)")
                continue
            }
            let a = document.store.joinedComponents()
            let b = reread.store.joinedComponents()
            var identical = a.count == b.count
            for (x, y) in zip(a, b) where x.decompressed != y.decompressed {
                identical = false
                log("      DIFFERS after round-trip: \(x.name)")
                Issue.record("\(name): \(x.name) differs after round-trip")
            }
            if identical { clean += 1 }
        }
        let supported = files.count - legacy
        log("corpus roundtrip CLEAN \(clean)/\(supported) (\(legacy) legacy '09 deck(s) skipped)")
        #expect(clean == supported)
    }
}
