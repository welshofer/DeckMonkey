import Foundation
import IWASnappy
import Testing
@testable import DeckMonkey

/// `Corpus/hostile/manifest.json`, written by `Scripts/make-hostile-corpus.py`.
struct HostileManifest: Decodable, Sendable {
    struct Entry: Decodable, Sendable, CustomTestStringConvertible {
        var file: String
        /// "open", "validate" or "save" — where the refusal must happen.
        var stage: String
        /// The typed error or validation-issue kind, e.g. "IWAChunkingError.truncated".
        var expects: String
        var note: String
        /// "registry": the raw store cannot judge this until the pinned registry is populated.
        var requires: String?

        var testDescription: String { "\(file) → \(expects) at \(stage)" }
        var url: URL { HostileManifest.directory.appendingPathComponent(file) }
    }

    var format: String
    var files: [Entry]

    static let directory = Paths.repoRoot.appendingPathComponent("Corpus/hostile")

    static func load() -> HostileManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(HostileManifest.self, from: data) else {
            return HostileManifest(format: "missing", files: [])
        }
        return manifest
    }
}

/// Does a thrown error match the manifest's `expects` name? One line per hostile rule, so a new
/// rule is a new line here and a new file in the corpus — never a looser match.
func matches(_ error: any Error, _ expects: String) -> Bool {
    switch expects {
    case "IWAPackageError.unsupportedLegacyFormat": if case IWAPackageError.unsupportedLegacyFormat = error { return true }
    case "IWAPackageError.notAnIWorkPackage": if case IWAPackageError.notAnIWorkPackage = error { return true }
    case "IWAPackageError.notAZip": if case IWAPackageError.notAZip = error { return true }
    case "IWAChunkingError.truncated": if case IWAChunkingError.truncated = error { return true }
    case "IWAChunkingError.invalidHeader": if case IWAChunkingError.invalidHeader = error { return true }
    case "SnappyError.invalidCopy": if case SnappyError.invalidCopy = error { return true }
    case "SnappyError.lengthMismatch": if case SnappyError.lengthMismatch = error { return true }
    case "ArchiveStreamError.truncated": if case ArchiveStreamError.truncated = error { return true }
    case "ArchiveStreamError.headerTooLong": if case ArchiveStreamError.headerTooLong = error { return true }
    case "ArchiveInfoError.missingIdentifier": if case ArchiveInfoError.missingIdentifier = error { return true }
    case "KeynoteError.schemaNewerThanLibrary": if case KeynoteError.schemaNewerThanLibrary = error { return true }
    case "KeynoteError.validationFailed": if case KeynoteError.validationFailed = error { return true }
    default: Issue.record("no matcher for expectation \(expects); add one here and a file in Corpus/hostile")
    }
    return false
}

func kindMatches(_ issue: ValidationIssue, _ expects: String) -> Bool {
    switch (issue.kind, expects) {
    case (.duplicateIdentifier, "ValidationIssue.duplicateIdentifier"),
         (.danglingObjectReference, "ValidationIssue.danglingObjectReference"),
         (.unknownType, "ValidationIssue.unknownType"),
         (.missingDataFile, "ValidationIssue.missingDataFile"):
        return true
    default:
        return false
    }
}

@Suite("AT-26 hostile corpus")
struct HostileCorpusTests {
    @Test("the manifest is present and names every file in Corpus/hostile")
    func manifestCoversDirectory() throws {
        let manifest = HostileManifest.load()
        #expect(manifest.format == "deckmonkey-hostile/1")
        #expect(manifest.files.count >= 14)
        let listed = Set(manifest.files.map(\.file))
        let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: HostileManifest.directory.path)
            .filter { $0.hasSuffix(".key") })
        #expect(listed == onDisk, "manifest and directory disagree: \(listed.symmetricDifference(onDisk))")
    }

    @Test("AT-26: each file raises its named error at its stage and writes nothing", arguments: HostileManifest.load().files)
    func refuses(_ entry: HostileManifest.Entry) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-hostile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.key")

        var opened: KeynoteDocument?
        var openError: (any Error)?
        do {
            opened = try KeynoteDocument.open(entry.url)
        } catch {
            openError = error
        }

        switch entry.stage {
        case "open":
            #expect(opened == nil, "\(entry.file) opened; it must be refused at open")
            if let openError {
                #expect(matches(openError, entry.expects), "\(entry.file) threw \(openError), expected \(entry.expects)")
            } else {
                Issue.record("\(entry.file): no error at open")
            }

        case "validate":
            guard let document = opened else {
                Issue.record("\(entry.file): failed to open (\(String(describing: openError))); expected to open and fail validation")
                return
            }
            if entry.requires == "registry", document.registry?.isEmpty ?? true {
                // Not judgeable by the raw store; the typed layer (Phase 0 step 3) turns this on.
                return
            }
            let issues = document.validate()
            #expect(issues.contains { $0.severity == .error && kindMatches($0, entry.expects) },
                    "\(entry.file): validator reported \(issues), expected an error of kind \(entry.expects)")
            var saveError: (any Error)?
            do {
                try document.save(to: output)
            } catch {
                saveError = error
            }
            #expect(saveError.map { matches($0, "KeynoteError.validationFailed") } == true,
                    "\(entry.file): save threw \(String(describing: saveError)), expected validationFailed")

        case "save":
            guard let document = opened else {
                Issue.record("\(entry.file): failed to open (\(String(describing: openError))); expected to open cleanly")
                return
            }
            #expect(document.validate().filter { $0.severity == .error }.isEmpty)
            var saveError: (any Error)?
            do {
                try document.save(to: output)
            } catch {
                saveError = error
            }
            #expect(saveError.map { matches($0, entry.expects) } == true,
                    "\(entry.file): save threw \(String(describing: saveError)), expected \(entry.expects)")

        default:
            Issue.record("\(entry.file): unknown stage \(entry.stage)")
        }

        #expect(!FileManager.default.fileExists(atPath: output.path), "\(entry.file): something was written")
    }
}

@Suite("AT-25 schema version gate")
struct SchemaVersionGateTests {
    @Test("BuildVersionHistory stamps parse by platform")
    func parse() {
        let mac = KeynoteBuild.parse("M15.4-7051.0.79-2")
        #expect(mac.platform == .macOS)
        #expect(mac.version == [15, 4])
        #expect(KeynoteBuild.parse("M6.5-2109-1").version == [6, 5])
        let ios = KeynoteBuild.parse("T2.5.1 (1715)")
        #expect(ios.platform == .iOS)
        #expect(ios.version == [2, 5, 1])
        let cloud = KeynoteBuild.parse("G-r11-2A396")
        #expect(cloud.platform == .iCloud)
        #expect(cloud.version == nil)
        #expect(KeynoteBuild.parse("").platform == .unknown)
        #expect(KeynoteBuild.parse("X1.2").platform == .unknown)
    }

    @Test("only a newer macOS stamp is newer than the pinned schema")
    func newer() {
        #expect(KeynoteBuild.parse("M16.0-8000.0.1-1").isNewer(thanPinned: "15.4"))
        #expect(KeynoteBuild.parse("M15.10-8000.0.1-1").isNewer(thanPinned: "15.4"))
        #expect(KeynoteBuild.parse("M15.4.1-7060.0.1-1").isNewer(thanPinned: "15.4"))
        #expect(!KeynoteBuild.parse("M15.4-7051.0.79-2").isNewer(thanPinned: "15.4"))
        #expect(!KeynoteBuild.parse("M6.5-2109-1").isNewer(thanPinned: "15.4"))
        #expect(!KeynoteBuild.parse("T2.5.1 (1715)").isNewer(thanPinned: "15.4"))
        #expect(!KeynoteBuild.parse("G-r11-2A396").isNewer(thanPinned: "15.4"))
        #expect(KeynoteBuild.compare([15, 4], [15, 4, 0]) == .orderedSame)
    }

    @Test("the pinned deck is writable; the synthetic deck reports its stamp")
    func syntheticIsWritable() throws {
        let document = try KeynoteDocument.open(Paths.fixtures.appendingPathComponent("synthetic-raw.key"))
        #expect(document.lastSavedBy == "M15.4-7051.0.79-2")
        #expect(!document.isNewerThanPinnedSchema)
    }
}

@Suite("AT-11 / AT-12 on the synthetic deck")
struct PreservationTests {
    static let synthetic = Paths.fixtures.appendingPathComponent("synthetic-raw.key")

    @Test("AT-11: metadata plists and every MessageInfo.version survive save byte-for-byte")
    func versionsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-at11-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.key")
        let original = try KeynoteDocument.open(Self.synthetic)
        try original.save(to: output)
        let reread = try KeynoteDocument.open(output)
        for name in original.package.entryNames where name.hasPrefix("Metadata/") {
            #expect(original.package.data(name) == reread.package.data(name), "\(name)")
        }
        #expect(original.package.buildVersionHistory == reread.package.buildVersionHistory)
        #expect(original.package.properties == reread.package.properties)
        for component in original.store.components {
            let after = reread.store.records(in: component.name) ?? []
            #expect(after.count == component.records.count, "\(component.name)")
            for (a, b) in zip(component.records, after) {
                #expect(a.info.messageInfos.map(\.version) == b.info.messageInfos.map(\.version), "\(component.name) \(a.identifier)")
                #expect(a.info.messageInfos.map(\.type) == b.info.messageInfos.map(\.type), "\(component.name) \(a.identifier)")
            }
        }
    }

    @Test("AT-12: an injected unknown header field survives a sibling mutation and a save to disk")
    func unknownFieldSurvives() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-at12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.key")

        let document = try KeynoteDocument.open(Self.synthetic)
        guard var record = document.store.record(for: 2) else {
            Issue.record("synthetic deck has no object 2")
            return
        }
        // Inject a field no schema knows (number 1234, length-delimited) into the ArchiveInfo header,
        // then mutate a sibling: the object_references list of the first MessageInfo.
        let marker = Data("from-the-future".utf8)
        var headerFields = record.info.fields
        headerFields.append(WireField(number: 1234, value: .lengthDelimited(marker)))
        record.info = try ArchiveInfo(bytes: Wire.encode(headerFields))
        #expect(record.info.messageInfos[0].objectReferences == [3])
        record.info.messageInfos[0].setObjectReferences([3, 1])

        var store = document.store
        store.replaceRecord(for: 2, with: record)
        var package = document.package
        for (name, decompressed) in store.joinedComponents() {
            package.set(name, try IWAChunking.compress(decompressed))
        }
        try package.write(to: output)

        let reread = try KeynoteDocument.open(output)
        #expect(reread.validate().isEmpty)
        let back = try #require(reread.store.record(for: 2))
        #expect(back.info.messageInfos[0].objectReferences == [3, 1])
        #expect(back.info.fields.contains(WireField(number: 1234, value: .lengthDelimited(marker))))
        #expect(back.payloads == record.payloads)
        // Everything else is untouched bytes.
        for id in [UInt64(1), 3, 11_006, 500] {
            #expect(reread.store.record(for: id) == document.store.record(for: id), "object \(id)")
        }
    }
}
