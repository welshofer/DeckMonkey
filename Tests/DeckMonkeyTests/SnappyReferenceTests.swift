import Foundation
import IWASnappy
import Testing
@testable import DeckMonkey

/// Same generator as `Scripts/snappy-crosscheck.py` (and IWASnappyTests): the fixture stores a
/// SHA-256 of every input, so a drift between the two implementations fails here, loudly.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Paths {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// The private corpus, if configured (same rules as KeynoteGraphTests.CorpusTests).
    static func corpusRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["DECKMONKEY_CORPUS"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        if let pointer = try? String(contentsOf: repoRoot.appendingPathComponent(".deckmonkey-corpus"), encoding: .utf8),
           let line = pointer.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
           !line.isEmpty {
            return URL(fileURLWithPath: (line as NSString).expandingTildeInPath)
        }
        return nil
    }

    /// `make snappy-reference` writes the corpus manifest here.
    static func corpusManifest() -> URL? {
        guard let root = corpusRoot() else { return nil }
        let url = root.appendingPathComponent(".snappy-reference.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// One entry of `Fixtures/snappy-vectors.json`.
struct Vector: Decodable, Sendable {
    struct Input: Decodable, Sendable {
        var kind: String
        var b64: String?
        var patternB64: String?
        var seed: UInt64?
        var length: Int?
        var period: Int?
        var multiplier: Int?

        enum CodingKeys: String, CodingKey {
            case kind, b64, seed, length, period, multiplier
            case patternB64 = "pattern_b64"
        }
    }

    var name: String
    var input: Input
    var inputSHA256: String
    var referenceB64: String

    enum CodingKeys: String, CodingKey {
        case name, input
        case inputSHA256 = "input_sha256"
        case referenceB64 = "reference_b64"
    }

    func makeInput() -> [UInt8] {
        let n = input.length ?? 0
        switch input.kind {
        case "bytes":
            return [UInt8](Data(base64Encoded: input.b64!)!)
        case "repeat":
            let pattern = [UInt8](Data(base64Encoded: input.patternB64!)!)
            return (0..<n).map { pattern[$0 % pattern.count] }
        case "period":
            let period = input.period!, multiplier = input.multiplier!
            return (0..<n).map { UInt8(truncatingIfNeeded: ($0 % period) * multiplier) }
        case "random":
            var rng = SplitMix64(seed: input.seed!)
            return (0..<n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        case "mixed":
            var rng = SplitMix64(seed: input.seed!)
            var out = [UInt8]()
            out.reserveCapacity(n)
            while out.count < n {
                let run = Int(rng.next() % 64) + 1
                let byte = UInt8(truncatingIfNeeded: rng.next())
                for _ in 0..<min(run, n - out.count) { out.append(byte) }
                if out.count < n, rng.next() % 4 == 0 {
                    out.append(UInt8(truncatingIfNeeded: rng.next()))
                }
            }
            return out
        default:
            Issue.record("unknown vector kind \(input.kind)")
            return []
        }
    }
}

struct VectorFile: Decodable, Sendable {
    var format: String
    var reference: String
    var vectors: [Vector]
}

@Suite("SHA-256")
struct SHA256Tests {
    @Test("FIPS 180-4 vectors, incremental and one-shot")
    func vectors() {
        #expect(SHA256.hex([UInt8]()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // A million 'a's, fed in uneven pieces so the 64-byte buffering is exercised.
        var hasher = SHA256.Hasher()
        var remaining = 1_000_000
        var piece = 1
        while remaining > 0 {
            let n = min(piece, remaining)
            hasher.update([UInt8](repeating: 0x61, count: n))
            remaining -= n
            piece = piece * 3 % 1_000 + 1
        }
        #expect(SHA256.hexString(hasher.finalize()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        #expect(SHA256.hex(Data("abc".utf8)) == SHA256.hex(Array("abc".utf8)))
    }
}

@Suite("AT-01 Snappy reference")
struct SnappyReferenceTests {
    static let vectorFile: VectorFile = {
        let url = Paths.fixtures.appendingPathComponent("snappy-vectors.json")
        return try! JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }()

    @Test("reference-compressed vectors decode to their inputs; our compression of them is written for the reference to verify")
    func vectorsDecode() throws {
        let file = Self.vectorFile
        #expect(file.format == "deckmonkey-snappy-vectors/1")
        #expect(file.vectors.count >= 30)
        var ours = [[String: String]]()
        for vector in file.vectors {
            let input = vector.makeInput()
            #expect(SHA256.hex(input) == vector.inputSHA256, "\(vector.name): generator drifted from snappy-crosscheck.py")
            let reference = [UInt8](Data(base64Encoded: vector.referenceB64)!)
            let decoded = try Snappy.decompress(reference)
            #expect(decoded == input, "\(vector.name): our decoder disagrees with the reference encoder")
            let compressed = Snappy.compress(input)
            #expect(try Snappy.decompress(compressed) == input, "\(vector.name)")
            ours.append(["name": vector.name, "ours_b64": Data(compressed).base64EncodedString()])
        }
        // The other direction needs the reference decoder, which is Python: hand it our output.
        // `make snappy-vectors` (CI runs it after the tests) decodes this with cramjam.
        let out = Paths.repoRoot.appendingPathComponent(".build/snappy-vectors-ours.json")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let doc: [String: Any] = [
            "format": "deckmonkey-snappy-vectors-ours/1",
            "fixture": Paths.fixtures.appendingPathComponent("snappy-vectors.json").path,
            "items": ours,
        ]
        try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]).write(to: out)
    }

    @Test("the synthetic deck's manifest from the reference decoder checks MATCH, and emits our re-compression")
    func syntheticDeck() throws {
        let manifest = Paths.fixtures.appendingPathComponent("synthetic-raw.snappy-reference.json")
        let emit = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-snappy-ours-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: emit) }
        let report = try SnappyReference.check(manifestAt: manifest, emitTo: emit)
        #expect(report.isClean, "\(report.mismatches)")
        #expect(report.decksChecked == 1)
        #expect(report.componentsChecked == 2)
        #expect(report.chunksChecked == 9)
        #expect(report.summaryLine.hasPrefix("snappy-check MATCH"))
        let emitted = try JSONDecoder().decode(SnappyReference.EmittedManifest.self, from: Data(contentsOf: emit.appendingPathComponent("manifest.json")))
        #expect(emitted.items.count == 2)
        for item in emitted.items {
            let iwa = try Data(contentsOf: emit.appendingPathComponent(item.file))
            #expect(SHA256.hex(try IWAChunking.decompress(iwa)) == item.decompressedSHA256)
        }
    }

    @Test("a wrong hash in the manifest is reported as exactly one mismatch, nothing is swallowed")
    func corruptedManifest() throws {
        var manifest = try SnappyReference.load(Paths.fixtures.appendingPathComponent("synthetic-raw.snappy-reference.json"))
        manifest.decks[0].components![0].chunkSHA256[3] = String(repeating: "0", count: 64)
        let report = try SnappyReference.check(manifest, relativeTo: Paths.fixtures)
        #expect(report.mismatches.count == 1)
        #expect(report.mismatches.first?.component == "Index/Document.iwa")
        #expect(report.mismatches.first?.detail.hasPrefix("chunk 3:") == true)
        #expect(report.chunksChecked == 9)

        var wrongCount = manifest   // still carries the bad chunk hash from above
        wrongCount.decks[0].components![1].chunks = 5
        wrongCount.decks[0].components![1].decompressedSHA256 = String(repeating: "f", count: 64)
        let report2 = try SnappyReference.check(wrongCount, relativeTo: Paths.fixtures)
        #expect(report2.mismatches.count == 3)   // the stale chunk hash from above, the count, the whole-stream hash

        var missing = manifest
        missing.decks[0].path = "does-not-exist.key"
        let report3 = try SnappyReference.check(missing, relativeTo: Paths.fixtures)
        #expect(report3.decksChecked == 0)
        #expect(report3.mismatches.count == 1)
    }

    @Test("manifests of another format are refused")
    func wrongFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-bad-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"format":"something-else/9","reference":"x","decks":[]}"#.utf8).write(to: url)
        #expect(throws: SnappyReference.Error.unsupportedFormat("something-else/9")) { try SnappyReference.load(url) }
    }

    @Test("AT-01: every chunk of every corpus deck decodes to what the reference decoder saw",
          .enabled(if: Paths.corpusManifest() != nil, "no reference manifest: run `make snappy-reference` (needs python3 + cramjam)"))
    func corpus() throws {
        let manifest = Paths.corpusManifest()!
        let emit = Paths.repoRoot.appendingPathComponent(".build/snappy-ours")
        try? FileManager.default.removeItem(at: emit)
        let report = try SnappyReference.check(manifestAt: manifest, emitTo: emit)
        let reportURL = Paths.repoRoot.appendingPathComponent(".build/snappy-report.txt")
        try? ([report.summaryLine] + report.mismatches.map(\.description)).joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        print(report.summaryLine)
        #expect(report.isClean, "\(report.mismatches.prefix(10))")
        #expect(report.decksChecked > 0)
    }
}

@Suite("Corpus manifest")
struct CorpusManifestTests {
    static let corpus = Paths.repoRoot.appendingPathComponent("Corpus")

    @Test("every in-repo corpus deck is in Corpus/manifest.json with its current digest", .enabled(if: FileManager.default.fileExists(atPath: CorpusManifestTests.corpus.appendingPathComponent("manifest.json").path)))
    func manifestMatchesDecks() throws {
        let manifest = try CorpusManifest.load(Self.corpus.appendingPathComponent("manifest.json"))
        var listed = Set<String>()
        for category in ["templates", "features"] {
            let dir = Self.corpus.appendingPathComponent(category)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".key") {
                let key = "\(category)/\(name)"
                listed.insert(key)
                let deck = dir.appendingPathComponent(name)
                // Without `git lfs pull` a deck is a pointer stub: its digest cannot be checked.
                if let head = try? FileHandle(forReadingFrom: deck).read(upToCount: 40), head.starts(with: Data("version https://git-lfs".utf8)) { continue }
                let entry = try #require(manifest.decks[key], "\(key) is not in the manifest: run make goldens")
                #expect(try CorpusManifest.digest(of: deck) == entry.sha256, "\(key) changed since it was added")
            }
        }
        #expect(Set(manifest.decks.keys) == listed, "manifest lists decks that are not in Corpus/")
    }
}
