import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import IWAArchive
import IWAContainer
import IWASnappy
import IWASchema
import SwiftProtobuf
import Testing
@testable import KeynoteGraph

/// A synthetic Keynote-shaped package: three components, identifier 1 the document, identifier 2
/// a real `TSP.PackageMetadata` in `Index/Metadata.iwa` (as in every corpus deck), a slide.
enum SynthDocument {
    static func record(id: UInt64, type: UInt32, payload: [UInt8], refs: [UInt64] = []) -> ArchiveRecord {
        var info = MessageInfo(type: type, version: [2, 0, 0], length: UInt32(payload.count))
        info.setObjectReferences(refs)
        return ArchiveRecord(info: ArchiveInfo(identifier: id, messageInfos: [info]), payloads: [Data(payload)])
    }

    /// What Keynote 15.4 writes, unless a test asks for a newer file.
    static func metadata(fileFormat: [UInt32] = TypeRegistry.pinnedFileFormatVersion) throws -> [UInt8] {
        var m = TSP_PackageMetadata()
        m.lastObjectIdentifier = 10_001
        m.readVersion = [2, 4, 0]
        m.writeVersion = [4, 1, 0]
        m.fileFormatVersion = fileFormat
        return [UInt8](try m.serializedData())
    }

    static let properties = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>fileFormatVersion</key><string>26.4.0</string></dict></plist>
        """

    static func package(fileFormat: [UInt32] = TypeRegistry.pinnedFileFormatVersion) throws -> IWAPackage {
        let document = ArchiveStream.join([
            record(id: 1, type: 1, payload: [UInt8](repeating: 7, count: 500), refs: [2, 10_000]),
        ])
        let metadata = ArchiveStream.join([record(id: 2, type: 11006, payload: try metadata(fileFormat: fileFormat))])
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
            "Index/Metadata.iwa": try IWAChunking.compress(metadata),
            "Index/Slide-10000.iwa": try IWAChunking.compress(slide),
            "Metadata/BuildVersionHistory.plist": Data(plist.utf8),
            "Metadata/Properties.plist": Data(properties.utf8),
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
        #expect(s.components == ["Index/Document.iwa", "Index/Metadata.iwa", "Index/Slide-10000.iwa"])
        #expect(s.objectCount == 4)
        #expect(s.recordCount == 4)
        #expect(s.mergeRecordCount == 0)
        #expect(s.highestIdentifier == 10_001)
        #expect(s.typeHistogram == [1: 1, 11006: 1, 5: 1, 2001: 1])
        #expect(document.packageMetadata?.fileFormatVersion == TypeRegistry.pinnedFileFormatVersion)
        #expect(document.writtenByNewerKeynote == nil)
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

    @Test("invariant 4: strong fields list, weak don't; edits never drop a held stored reference; unseen fields refuse only new references")
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
        // A record an older Keynote archived may list a reference 15.4 calls weak: an edit keeps it
        // while the payload still holds it, and drops it once the payload does not.
        let old = refs([(60, "A.2"), (61, "A.1")])
        #expect(try ReferenceDerivation.listedObjects(old, strength: strength, original: (old, [60, 61])) == [60, 61])
        #expect(try ReferenceDerivation.listedObjects(refs([(61, "A.1")]), strength: strength, original: (old, [60, 61])) == [61])
        // An unknown field that only holds what the original held is decided by the stored list.
        let unknown = refs([(70, "B.9"), (71, "B.9")])
        #expect(try ReferenceDerivation.listedObjects(unknown, strength: strength, original: (unknown, [70])) == [70])
        #expect(throws: ReferenceDerivation.ListingFailure.unclassifiedField("B.9")) {
            try ReferenceDerivation.listedObjects(refs([(70, "B.9"), (72, "B.9")]), strength: strength, original: (unknown, [70]))
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

    @Test("AT-25: the file format decides; a newer one opens and reads, and any write raises schemaNewerThanLibrary", arguments: [
        // file format, write version, read-only?
        ([27, 0, 0] as [UInt32], [4, 1, 0] as [UInt32], true),
        ([26, 4, 1] as [UInt32], [4, 1, 0] as [UInt32], true),
        // Keynote 15.4's own saves: write_version varies with content (4.1.0, 11.2.4) and is no stamp.
        ([26, 4, 0] as [UInt32], [11, 2, 4] as [UInt32], false),
        ([1, 5, 0] as [UInt32], [1, 2, 0] as [UInt32], false),
    ])
    func newerKeynoteIsReadOnly(fileFormat: [UInt32], writeVersion: [UInt32], readOnly: Bool) throws {
        var package = try SynthDocument.package(fileFormat: fileFormat)
        var m = TSP_PackageMetadata()
        m.lastObjectIdentifier = 10_001
        m.readVersion = [2, 4, 0]
        m.writeVersion = writeVersion
        m.fileFormatVersion = fileFormat
        let payload = [UInt8](try m.serializedData())
        package.set("Index/Metadata.iwa", try IWAChunking.compress(ArchiveStream.join([SynthDocument.record(id: 2, type: 11006, payload: payload)])))
        let document = try KeynoteDocument.open(package)
        #expect(document.summary.objectCount == 4)          // reads through the raw store either way
        #expect((document.writtenByNewerKeynote != nil) == readOnly)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-newer-\(UUID().uuidString).key")
        defer { try? FileManager.default.removeItem(at: out) }
        if readOnly {
            #expect {
                try document.save(to: out)
            } throws: { error in
                guard case .schemaNewerThanLibrary(_, let pinned)? = error as? KeynoteError else { return false }
                return pinned == "15.4 (7051.0.79)"
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
        } else {
            try document.save(to: out)
            #expect(FileManager.default.fileExists(atPath: out.path))
        }
        #expect(!TypeRegistry.isNewer([26, 4, 0], than: [26, 4, 0]) && TypeRegistry.isNewer([26, 4, 1], than: [26, 4]) && !TypeRegistry.isNewer([1, 5, 0], than: [26, 4, 0]))
    }

    @Test("AT-11 shape: plists, PackageMetadata versions and every MessageInfo.version are byte-identical after save")
    func versionsInherited() throws {
        let package = try SynthDocument.package()
        let document = try KeynoteDocument.open(package)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-at11-\(UUID().uuidString).key")
        defer { try? FileManager.default.removeItem(at: out) }
        try document.save(to: out)
        let reread = try KeynoteDocument.open(out)
        #expect(CorpusTests.versionDifferences(document, reread).isEmpty)
    }

    @Test("AT-12 shape: an injected unknown field survives decode, mutation of a sibling field, and encode")
    func unknownFieldSurvivesMutation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-at12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var document = try KeynoteDocument.open(try SynthDocument.package())
        try CorpusTests.injectUnknownFieldAndMutate(&document, scratch: dir)
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

    /// AT-11: what save must leave byte-identical. Empty when nothing differs.
    static func versionDifferences(_ a: KeynoteDocument, _ b: KeynoteDocument) -> [String] {
        var out = [String]()
        for name in ["Metadata/Properties.plist", "Metadata/BuildVersionHistory.plist"] where a.package.data(name) != b.package.data(name) {
            out.append("\(name) differs")
        }
        if let x = a.packageMetadata, let y = b.packageMetadata {
            if x.readVersion != y.readVersion || x.writeVersion != y.writeVersion || x.fileFormatVersion != y.fileFormatVersion {
                out.append("PackageMetadata versions differ")
            }
        } else if (a.packageMetadata == nil) != (b.packageMetadata == nil) {
            out.append("PackageMetadata decodes on one side only")
        }
        for id in a.store.identifiers {
            let va = a.store.record(for: id)?.info.messageInfos.map(\.version)
            let vb = b.store.record(for: id)?.info.messageInfos.map(\.version)
            if va != vb { out.append("object \(id): MessageInfo.version \(String(describing: va)) → \(String(describing: vb))"); if out.count > 10 { break } }
        }
        return out
    }

    /// AT-12 on `document`'s PackageMetadata (identifier 2): inject an unknown field, save, reopen,
    /// mutate a sibling field, save, reopen; the unknown field must survive byte for byte and the
    /// header's reference lists must not move.
    static func injectUnknownFieldAndMutate(_ document: inout KeynoteDocument, scratch: URL) throws {
        let original = try #require(document.store.record(for: 2), "no PackageMetadata")
        let unknown: [UInt8] = [0xF8, 0xF0, 0x04, 0x07]          // field 9999, varint 7: not in TSP.PackageMetadata
        try document.replacePayload(of: 2, with: original.payloads[0] + unknown)
        let first = scratch.appendingPathComponent("injected.key")
        try document.save(to: first)

        var reopened = try KeynoteDocument.open(first)
        var metadata = try #require(reopened.packageMetadata)
        #expect(Array(metadata.unknownFields.data) == unknown)
        metadata.saveToken = 4242
        try reopened.replacePayload(of: 2, with: try metadata.serializedData())
        let second = scratch.appendingPathComponent("mutated.key")
        try reopened.save(to: second)

        let final = try KeynoteDocument.open(second)
        let decoded = try #require(final.packageMetadata)
        #expect(decoded.saveToken == 4242)
        #expect(Array(decoded.unknownFields.data) == unknown)
        let info = try #require(final.store.record(for: 2)?.info.messageInfos.first)
        let before = try #require(original.info.messageInfos.first)
        #expect(info.objectReferences == before.objectReferences)
        #expect(info.dataReferences == before.dataReferences)
        #expect(info.version == before.version)
        #expect(final.validate().filter { $0.severity == .error }.isEmpty)
    }

    static func corpusFiles() -> [URL] {
        var files = [URL]()
        for root in corpusRoots() {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator {
                if url.lastPathComponent == "hostile" && url.deletingLastPathComponent().lastPathComponent == "Corpus" {
                    enumerator.skipDescendants()   // deliberately broken copies: AT-26, not corpus decks
                    continue
                }
                guard url.pathExtension.lowercased() == "key" else { continue }
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

    /// AT-06/07/08 against the strength table `make reference-strength` learns from the in-repo decks
    /// Keynote 15.4 authored (Registry/reference-strength-15.4.json):
    /// - AT-07, decks saved only by the pinned Keynote: the rule alone reproduces every stored
    ///   object_references set (references held only in mixed fields are exempt and counted);
    /// - AT-07, older decks: stored ⊆ derived, and the edit rule never drops a stored reference;
    ///   how far each list sits from the 15.4 rule is reported (records an older Keynote archived);
    /// - AT-08: data_references are exactly the derived DataReference ids minus 0 (null sentinel);
    /// - AT-06: every listed reference resolves; unlisted ones may dangle, as in Keynote's own files.
    @Test("AT-06/07/08: the strong-reference rule against Keynote's stored lists", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus: set DECKMONKEY_CORPUS, write .deckmonkey-corpus, or add decks under Corpus/"))
    func corpusReferences() throws {
        let strength = try ReferenceStrength.load(version: TypeRegistry.pinnedVersion)
        var pinnedDecks = 0, olderDecks = 0, pinnedPayloads = 0, olderPayloads = 0
        var mixedExempt = 0, drift = 0, danglingUnlisted = 0, deprecated = 0
        var failures = [String]()
        func fail(_ message: String) { if failures.count < 20 { failures.append(message) } }
        for url in CorpusTests.corpusFiles() {
            guard let document = try? KeynoteDocument.open(url) else { continue }
            let pinned = document.authoredByPinnedKeynote
            if pinned { pinnedDecks += 1 } else { olderDecks += 1 }
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
                        if pinned { pinnedPayloads += 1 } else { olderPayloads += 1 }
                        if derived.hasUnknownFields { fail("\(label): unknown fields under the pinned schema") }
                        // AT-08
                        if Set(info.dataReferences) != Set(derived.data).subtracting([0]) {
                            fail("\(label): data_references \(info.dataReferences), derived \(derived.data)")
                        }
                        let stored = Set(info.objectReferences)
                        if !stored.isSubset(of: derived.objects) {
                            fail("\(label): lists \(stored.subtracting(derived.objects).sorted()) not in the payload")
                        }
                        // AT-07
                        if pinned {
                            do {
                                let rule = try ReferenceDerivation.listedObjects(derived, strength: strength)
                                let onlyMixed = Set(zip(derived.objects, derived.objectFields).map(\.0)).filter { ref in
                                    zip(derived.objects, derived.objectFields).allSatisfy { $0.0 != ref || strength.strength(of: $0.1) == .mixed }
                                }
                                let difference = rule.symmetricDifference(stored)
                                mixedExempt += difference.intersection(onlyMixed).count
                                let unexplained = difference.subtracting(onlyMixed)
                                if !unexplained.isEmpty {
                                    fail("\(label): rule lists \(rule.subtracting(stored).intersection(unexplained).sorted()) extra, \(stored.subtracting(rule).intersection(unexplained).sorted()) missing")
                                }
                            } catch {
                                fail("\(label): \(error)")
                            }
                        } else {
                            if let rule = try? ReferenceDerivation.listedObjects(derived, strength: strength), rule != stored { drift += 1 }
                            do {
                                let edit = try ReferenceDerivation.listedObjects(derived, strength: strength, original: (derived, info.objectReferences))
                                if !stored.isSubset(of: edit) { fail("\(label): the edit rule drops \(stored.subtracting(edit).sorted())") }
                            } catch {
                                fail("\(label): \(error)")
                            }
                        }
                        // AT-06
                        for ref in derived.objects where document.store.entry(for: ref) == nil {
                            if stored.contains(ref) { fail("\(label): listed reference \(ref) is dangling") } else { danglingUnlisted += 1 }
                        }
                    }
                }
            }
        }
        print("references: \(pinnedDecks) deck(s) saved only by \(TypeRegistry.pinnedVersion), \(pinnedPayloads) payloads reproduced by the rule "
            + "(\(mixedExempt) references held only in mixed fields exempt); \(olderDecks) older deck(s), \(olderPayloads) payloads, "
            + "\(drift) lists differ from the \(TypeRegistry.pinnedVersion) rule and are preserved by edits; "
            + "\(deprecated) deprecated-type payloads; \(danglingUnlisted) dangling unlisted references")
        failures.forEach { print("  FAIL \($0)") }
        #expect(failures.isEmpty)
    }

    /// AT-26: every file in Corpus/hostile raises the error expected.json names, and writes nothing.
    @Test("AT-26: each Corpus/hostile file raises its named error and writes nothing", .enabled(if: FileManager.default.fileExists(atPath: CorpusTests.repoRoot.appendingPathComponent("Corpus/hostile/expected.json").path), "no Corpus/hostile: run `deckmonkey corpus hostile`"))
    func hostileCorpus() throws {
        let dir = CorpusTests.repoRoot.appendingPathComponent("Corpus/hostile")
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appendingPathComponent("expected.json")))
            .filter { !$0.key.hasPrefix("_") }
        #expect(Set(expected.values) == ["duplicateIdentifier", "danglingObjectReference", "componentUnreadable", "unknownType", "textOffset"])
        for (file, error) in expected.sorted(by: { $0.key < $1.key }) {
            let url = dir.appendingPathComponent(file)
            let document: KeynoteDocument
            do {
                document = try KeynoteDocument.open(url)
            } catch let failure as KeynoteError {
                guard case .componentUnreadable = failure, error == "componentUnreadable" else {
                    Issue.record("\(file): open raised \(failure), expected \(error)")
                    continue
                }
                continue                                   // refused at open: nothing to write
            }
            let errors = document.validate().filter { $0.severity == .error }
            let kinds = Set(errors.map { "\($0.kind)".prefix(while: { $0 != "(" }) }.map(String.init))
            #expect(kinds == [error], "\(file): \(errors)")
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-hostile-\(UUID().uuidString).key")
            #expect(throws: KeynoteError.self, "\(file)") { try document.save(to: out) }
            #expect(!FileManager.default.fileExists(atPath: out.path), "\(file) wrote output")
        }
    }

    /// Phase 1 groundwork: decoding a storage and encoding it again, with an empty edit, must give
    /// Keynote's bytes back exactly. Any field the encoder adds (an empty table it never wrote) makes
    /// Keynote "upgrade" the storage on read, which the oracle reports as persistence errors.
    @Test("every corpus text storage re-encodes byte for byte through an empty edit", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus"))
    func corpusStorageIdentity() throws {
        var storages = 0
        var differ = [String]()
        for url in CorpusTests.corpusFiles() {
            guard let document = try? KeynoteDocument.open(url) else { continue }
            for component in document.store.components {
                for record in component.records {
                    guard let info = record.info.messageInfos.first, info.type == 2001, info.baseMessageIndex == nil else { continue }
                    let storage = try TSWP_StorageArchive(serializedBytes: record.payloads[0], extensions: Schema.extensions, partial: true)
                    guard storage.text.count == 1 else { continue }
                    storages += 1
                    let (same, _) = try TextReplace.apply(storage, range: 0..<0, with: "")
                    let bytes: Data = try same.serializedData(partial: true)
                    if bytes != record.payloads[0], differ.count < 10 {
                        differ.append("\(url.lastPathComponent) storage \(record.identifier): \(record.payloads[0].count) → \(bytes.count) bytes")
                    }
                }
            }
        }
        print("storage identity: \(storages) storages, \(differ.count) re-encode differently")
        differ.forEach { print("  \($0)") }
        #expect(differ.isEmpty)
    }

    /// Phase 1 as a property over the corpus: in every storage, replace the first two UTF-16 units
    /// with a longer string. Each result keeps valid offset tables (or the rule refuses, for a
    /// paragraph break or an anchored object), and each edited deck saves, reopens and validates.
    @Test("replace in every corpus storage: tables stay valid, every edited deck saves, reopens and validates", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus"))
    func corpusReplaceEverywhere() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var edited = 0, refused = 0, decks = 0
        var failures = [String]()
        for url in CorpusTests.corpusFiles() {
            guard var document = try? KeynoteDocument.open(url), document.writtenByNewerKeynote == nil else { continue }
            var touched = false
            for (id, text) in document.textStorages where text.utf16.count >= 2 {
                do {
                    try document.replaceText(in: id, range: 0..<2, with: "Replaced·")
                    edited += 1
                    touched = true
                } catch is TextReplace.Failure {
                    refused += 1
                } catch {
                    if failures.count < 10 { failures.append("\(url.lastPathComponent) storage \(id): \(error)") }
                }
            }
            guard touched else { continue }
            decks += 1
            let out = dir.appendingPathComponent("\(decks).key")
            do {
                try document.save(to: out)
                let reread = try KeynoteDocument.open(out)
                let errors = reread.validate().filter { $0.severity == .error }
                if !errors.isEmpty, failures.count < 10 { failures.append("\(url.lastPathComponent): \(errors.prefix(3))") }
            } catch {
                if failures.count < 10 { failures.append("\(url.lastPathComponent): \(error)") }
            }
            try? FileManager.default.removeItem(at: out)
        }
        print("replace everywhere: \(edited) storages edited in \(decks) decks, \(refused) refused by the Phase 1 rules, \(failures.count) failure(s)")
        failures.forEach { print("  \($0)") }
        #expect(failures.isEmpty)
    }

    /// Gate 1's frame check rests on `location(of:)`: in every template deck, each layout caption
    /// ("<theme> · <layout>", one title per slide) resolves to its own page, in slide order.
    @Test("every template caption locates to a distinct PDF page", .enabled(if: FileManager.default.fileExists(atPath: CorpusTests.repoRoot.appendingPathComponent("Corpus/templates").path), "no Corpus/templates"))
    func templateCaptionsLocate() throws {
        let dir = CorpusTests.repoRoot.appendingPathComponent("Corpus/templates")
        var decks = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".key") {
            let document = try KeynoteDocument.open(dir.appendingPathComponent(name))
            let slides = document.pageOfSlide.count
            let captions = document.textStorages.filter { $0.text.contains(" · ") && !$0.text.hasSuffix(" body") }
            let pages = captions.compactMap { document.location(of: $0.identifier)?.page }
            #expect(pages.count == captions.count, "\(name): a caption did not locate")
            #expect(Set(pages).count == pages.count, "\(name): two captions on one page")
            // Layouts without a title (Blank, Photo) carry no caption: captions cover a subset of pages.
            #expect(Set(pages).isSubset(of: Set(1...max(slides, 1))), "\(name): caption pages \(pages.sorted()) for \(slides) slides")
            #expect(pages.count * 2 >= slides, "\(name): only \(pages.count) captions for \(slides) slides")
            decks += 1
        }
        #expect(decks == 106)
    }

    #if canImport(CoreGraphics)
    /// `pageOfSlide` against Keynote itself: for every in-repo deck with a golden PDF, the number of
    /// pages derived from the slide tree equals the golden's page count.
    @Test("derived PDF page counts equal Keynote's exports", .enabled(if: FileManager.default.fileExists(atPath: CorpusTests.repoRoot.appendingPathComponent("Corpus/manifest.json").path), "no local corpus"))
    func pageCountsMatchGoldens() throws {
        var checked = 0
        for category in ["templates", "features"] {
            let dir = CorpusTests.repoRoot.appendingPathComponent("Corpus/\(category)")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".golden.pdf") {
                let deck = dir.appendingPathComponent(String(name.dropLast(".golden.pdf".count)) + ".key")
                guard let pdf = CGPDFDocument(dir.appendingPathComponent(name) as CFURL),
                      let document = try? KeynoteDocument.open(deck) else { continue }
                #expect(document.pageOfSlide.count == pdf.numberOfPages, "\(category)/\(name)")
                checked += 1
            }
        }
        #expect(checked > 0)
    }
    #endif

    /// Invariant 8 for text, against Keynote's own files: every TSWP.StorageArchive's offset tables
    /// are strictly increasing and within the UTF-16 text length.
    @Test("text offset tables in every Keynote-authored storage are sorted and in range", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus: set DECKMONKEY_CORPUS, write .deckmonkey-corpus, or add decks under Corpus/"))
    func corpusTextOffsets() throws {
        var storages = 0, entries = 0, atEnd = 0
        var problems = [String]()
        for url in CorpusTests.corpusFiles() {
            guard let document = try? KeynoteDocument.open(url) else { continue }
            for component in document.store.components {
                for record in component.records {
                    for (i, info) in record.info.messageInfos.enumerated() where info.type == 2001 && info.baseMessageIndex == nil {
                        let storage = try TSWP_StorageArchive(serializedBytes: record.payloads[i], extensions: Schema.extensions, partial: true)
                        storages += 1
                        let length = TextOffsets.textLength(storage)
                        let paraStyle = storage.tableParaStyle.entries.map(\.characterIndex)
                        entries += paraStyle.count
                        atEnd += paraStyle.filter { Int($0) == length }.count
                        for p in TextOffsets.problems(in: storage) where problems.count < 30 {
                            problems.append("\(url.lastPathComponent) object \(record.identifier): \(p)")
                        }
                    }
                }
            }
        }
        print("text offsets: \(storages) storages, \(entries) paragraph-style entries (\(atEnd) at the text length), \(problems.count) problem(s)")
        problems.forEach { print("  \($0)") }
        #expect(problems.isEmpty)
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
                    case .textOffset: kind = "textOffset"
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
            // AT-11: versions are inherited, never bumped.
            for difference in Self.versionDifferences(document, reread) {
                log("      AT-11: \(difference)")
                Issue.record("\(name): AT-11: \(difference)")
            }
            // AT-12 on a copy: an injected unknown field survives a sibling mutation.
            let scratch = dir.appendingPathComponent("at12-\(clean)-\(name)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            var copy = document
            do {
                try Self.injectUnknownFieldAndMutate(&copy, scratch: scratch)
            } catch {
                log("      AT-12 FAILED: \(error)")
                Issue.record("\(name): AT-12: \(error)")
            }
        }
        let supported = files.count - legacy
        log("corpus roundtrip CLEAN \(clean)/\(supported) (\(legacy) legacy '09 deck(s) skipped)")
        #expect(clean == supported)
    }
}
