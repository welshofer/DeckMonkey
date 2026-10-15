import DeckMonkey
import Foundation

// deckmonkey — the acceptance surface (docs/spec.md §13). Every gate is one of these subcommands
// with a machine-readable exit code: 0 pass, 1 fail, 2 usage error, 3 refused by design (a
// Keynote '09 APXL file: out of scope, docs/spec.md §2, so neither a pass nor a failure).

enum CLI {
    static let usage = """
    usage: deckmonkey <command> [options]

      inspect <file>                 components, object counts, type histogram, versions
      dump <file> [component]        every record: identifier, types, versions, lengths, references
      roundtrip <file> [-o out.key]  open, save, re-open; prints CLEAN n/n or the first difference
      verify <file>                  validator (oracle harness wiring arrives with Scripts/oracle.sh)
      snappy-check <ref.json> [--emit <dir>]
                                     AT-01: re-derive every chunk hash in a reference manifest
                                     (Scripts/snappy-crosscheck.py hash) with our decoder; with
                                     --emit, also write our re-compression for verify-ours
      reference-strength --out <json> <deck or dir>...
                                     learn which reference fields Keynote lists (invariant 4)
                                     from Keynote-authored decks; `make reference-strength`
      corpus add [--category <c>] <deck>...
                                     file decks under Corpus/<c> (default templates) with a golden
                                     PDF from the Keynote oracle and a Corpus/manifest.json entry;
                                     refuses a deck that does not open cleanly (macOS, Keynote)
      corpus hostile --from <template.key> [--out Corpus/hostile]
                                     AT-26: one broken copy of a Keynote-authored template per
                                     validator rule, plus expected.json naming each one's error
      text <file>                    every TSWP text storage: identifier and its text (read-only)
      version

    Exit codes: 0 pass, 1 fail, 2 usage, 3 refused (Keynote '09 APXL, out of scope).
    """
}
let usage = CLI.usage

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func url(_ path: String) -> URL {
    URL(fileURLWithPath: path)
}

/// The value after `flag`, nil when the flag is absent. A flag with no value is a usage error,
/// never a silent default: a gate script with an empty `$OUT` must not pass on a temp file.
func option(_ flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
        fail("error: \(flag) needs a value\n\n\(CLI.usage)", code: 2)
    }
    return args[i + 1]
}

func runInspect(_ args: [String]) throws {
    guard let path = args.first else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(path))
    let s = document.summary
    print("file: \(path)")
    print("form: \(document.package.form) nestedIndex=\(document.package.nestedIndex)")
    print("fileFormatVersion: \(s.fileFormatVersion ?? "-")")
    print("documentIdentifier: \(s.documentIdentifier ?? "-")")
    print("buildVersionHistory: \(s.buildVersionHistory.joined(separator: " → "))")
    if let m = document.packageMetadata {
        func v(_ x: [UInt32]) -> String { x.map(String.init).joined(separator: ".") }
        print("packageMetadata: read \(v(m.readVersion)) write \(v(m.writeVersion)) fileFormat \(v(m.fileFormatVersion)) lastObjectIdentifier \(m.lastObjectIdentifier)")
    }
    print("components: \(s.components.count)")
    for name in s.components {
        let count = document.store.records(in: name)?.count ?? 0
        print("  \(name)  \(count) record\(count == 1 ? "" : "s")")
    }
    print("objects: \(s.objectCount)  records: \(s.recordCount)  merges: \(s.mergeRecordCount)  highest identifier: \(s.highestIdentifier)")
    print("data entries: \(s.dataEntries)")
    print("types:")
    for (type, count) in s.typeHistogram.sorted(by: { $0.key < $1.key }) {
        let name = document.registry?.name(for: type).map { " \($0)" } ?? ""
        print("  \(type)\(name): \(count)")
    }
    let issues = document.validate()
    if issues.isEmpty {
        print("validation: clean")
    } else {
        print("validation: \(issues.count) issue(s)")
        for issue in issues.prefix(50) {
            print("  \(issue)")
        }
    }
}

func runDump(_ args: [String]) throws {
    guard let path = args.first else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(path))
    let components = args.count > 1 ? [args[1]] : document.store.componentNames
    for name in components {
        guard let records = document.store.records(in: name) else {
            fail("error: no component named \(name); components:\n" + document.store.componentNames.map { "  \($0)" }.joined(separator: "\n"))
        }
        print("# \(name)")
        for record in records {
            let merge = record.shouldMerge ? " merge" : ""
            print("- \(record.identifier)\(merge)")
            for (i, info) in record.info.messageInfos.enumerated() {
                let typeName = document.registry?.name(for: info.type).map { " \($0)" } ?? ""
                var line = "    [\(i)] type \(info.type)\(typeName) version \(info.version) length \(info.length)"
                if !info.objectReferences.isEmpty { line += " refs \(info.objectReferences)" }
                if !info.dataReferences.isEmpty { line += " data \(info.dataReferences)" }
                print(line)
            }
        }
    }
}

func runRoundtrip(_ args: [String]) throws {
    guard let path = args.first else { fail(CLI.usage, code: 2) }
    let output: URL
    if let o = option("-o", in: args) {
        output = url(o)
    } else {
        output = FileManager.default.temporaryDirectory
            .appendingPathComponent("deckmonkey-roundtrip-\(UUID().uuidString)")
            .appendingPathExtension(url(path).pathExtension.isEmpty ? "key" : url(path).pathExtension)
    }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let report = try DeckMonkey.roundTrip(url(path), to: output)
    print("roundtrip \(report.summaryLine)")
    print("output: \(output.path)")
    if !report.isClean {
        for d in report.different.prefix(20) {
            print("  \(d.component)" + (d.firstDifferingIdentifier.map { " first differing identifier \($0)" } ?? ""))
        }
        exit(1)
    }
}

func runVerify(_ args: [String]) throws {
    guard let path = args.first else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(path))
    let issues = document.validate()
    for issue in issues {
        print(issue)
    }
    let errors = issues.filter { $0.severity == .error }
    print(errors.isEmpty ? "validator: pass (\(issues.count) warning(s))" : "validator: FAIL (\(errors.count) error(s))")
    print("oracle: not run — see Scripts/oracle.sh (macOS, Keynote required)")
    if !errors.isEmpty { exit(1) }
}

func runSnappyCheck(_ args: [String]) throws {
    guard let path = args.first else { fail(CLI.usage, code: 2) }
    let emit = option("--emit", in: args).map(url)
    let report = try SnappyReference.check(manifestAt: url(path), emitTo: emit)
    print(report.summaryLine)
    for mismatch in report.mismatches.prefix(50) {
        print("  \(mismatch)")
    }
    if let emit {
        print("emitted: \(emit.path)/manifest.json (verify with Scripts/snappy-crosscheck.py verify-ours)")
    }
    if !report.isClean { exit(1) }
}

/// Every `.key` under the given paths (a `.key` may itself be a package directory).
func keyFiles(_ paths: [String]) -> [URL] {
    var files = [URL]()
    for path in paths {
        let root = url(path)
        if root.pathExtension.lowercased() == "key" { files.append(root); continue }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let file as URL in walker where file.pathExtension.lowercased() == "key" {
            files.append(file)
            walker.skipDescendants()
        }
    }
    return files.sorted { $0.path < $1.path }
}

func runReferenceStrength(_ args: [String]) throws {
    guard let out = option("--out", in: args) else { fail(CLI.usage, code: 2) }
    var paths = args
    if let i = paths.firstIndex(of: "--out") { paths.removeSubrange(i...(i + 1)) }
    let files = keyFiles(paths)
    guard !files.isEmpty else { fail("error: no .key files under \(paths.joined(separator: ", "))", code: 2) }
    var learner = ReferenceStrengthLearner()
    var refused = 0, notPinned = 0
    for file in files {
        let document: KeynoteDocument
        do {
            document = try DeckMonkey.open(file)
        } catch IWAPackageError.unsupportedLegacyFormat {
            refused += 1
            continue
        }
        // Only decks the pinned Keynote archived entirely: an older save leaves records whose lists
        // follow that Keynote's rule, not the one DeckMonkey writes by.
        guard document.authoredByPinnedKeynote else {
            notPinned += 1
            continue
        }
        learner.observeDeck()
        for component in document.store.components {
            for record in component.records {
                for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil {
                    guard let derived = try? ReferenceDerivation.derive(type: info.type, payload: record.payloads[i]) else { continue }
                    learner.observe(derived, stored: info.objectReferences)
                }
            }
        }
    }
    guard learner.decks > 0 else { fail("error: no deck under \(paths.joined(separator: ", ")) was saved only by Keynote \(TypeRegistry.pinnedVersion)") }
    let result = learner.result(source: "deckmonkey reference-strength over \(learner.decks) deck(s) saved only by Keynote \(TypeRegistry.pinnedVersion)")
    try result.encoded().write(to: url(out))
    let counts = Dictionary(grouping: result.fields.values, by: \.strength).mapValues(\.count)
    print("reference-strength: \(result.fields.count) fields from \(result.payloads) payloads in \(result.decks) deck(s) "
        + "(\(refused) refused, \(notPinned) skipped: saved by another Keynote): "
        + "\(counts[.strong] ?? 0) strong, \(counts[.weak] ?? 0) weak, \(counts[.mixed] ?? 0) mixed -> \(out)")
    for (name, field) in result.fields.sorted(by: { $0.key < $1.key }) where field.strength == .mixed {
        print("  mixed \(name): \(field.occurrences) seen, \(field.unlisted) unlisted, \(field.unexplainedListed) listed without a strong twin")
    }
}

/// Runs a command, returning its exit status and standard output.
func run(_ executable: String, _ args: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

func runCorpusAdd(_ args: [String]) throws {
    let category = option("--category", in: args) ?? "templates"
    var decks = args
    if let i = decks.firstIndex(of: "--category") { decks.removeSubrange(i...(i + 1)) }
    let corpus = url("Corpus")
    let oracle = "Scripts/oracle.sh"
    guard FileManager.default.isExecutableFile(atPath: oracle) else { fail("error: run from the repository root (needs \(oracle))", code: 2) }
    guard !decks.isEmpty else { fail(CLI.usage, code: 2) }
    let manifestURL = corpus.appendingPathComponent("manifest.json")
    var manifest = try CorpusManifest.load(manifestURL)
    let directory = corpus.appendingPathComponent(category)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var added = 0, refused = 0
    for path in decks {
        let source = url(path).standardizedFileURL
        let deck = directory.appendingPathComponent(source.lastPathComponent).standardizedFileURL
        if source.path != deck.path {
            if FileManager.default.fileExists(atPath: deck.path) { try FileManager.default.removeItem(at: deck) }
            try FileManager.default.copyItem(at: source, to: deck)
        }
        let document = try DeckMonkey.open(deck)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-corpus-add-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let verdict = try run(oracle, [deck.path, "--out", scratch.path])
        struct Verdict: Decodable { let pass: Bool; let pdf: String; let keynoteVersion: String; let sheet: String? }
        guard let parsed = try? JSONDecoder().decode(Verdict.self, from: Data(verdict.output.utf8)), parsed.pass, !parsed.pdf.isEmpty else {
            print("refused \(deck.lastPathComponent): the original does not pass the oracle: \(verdict.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            refused += 1
            continue
        }
        let golden = deck.deletingPathExtension().appendingPathExtension("golden.pdf")
        if FileManager.default.fileExists(atPath: golden.path) { try FileManager.default.removeItem(at: golden) }
        try FileManager.default.moveItem(at: URL(fileURLWithPath: parsed.pdf), to: golden)
        let key = "\(category)/\(deck.lastPathComponent)"
        manifest.decks[key] = CorpusManifest.Entry(
            sha256: try CorpusManifest.digest(of: deck),
            savedBy: document.lastSavedBy ?? "-",
            fileFormatVersion: document.packageMetadata.map { $0.fileFormatVersion.map(String.init).joined(separator: ".") } ?? "-",
            oracleKeynote: parsed.keynoteVersion)
        try manifest.write(to: manifestURL)   // after every deck: an interrupted run keeps what it did
        print("added \(key)")
        added += 1
    }
    print("corpus add: \(added) added, \(refused) refused → \(manifestURL.path)")
    if refused > 0 { exit(1) }
}

func runCorpusHostile(_ args: [String]) throws {
    guard let from = option("--from", in: args) else { fail(CLI.usage, code: 2) }
    let out = url(option("--out", in: args) ?? "Corpus/hostile")
    let template = try DeckMonkey.open(url(from))
    guard template.authoredByPinnedKeynote else { fail("error: \(from) was not saved only by Keynote \(TypeRegistry.pinnedVersion)") }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var expected = [String: String]()
    for c in try HostileCorpus.cases(from: template) {
        let file = out.appendingPathComponent("\(c.name).key")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try c.package.write(to: file)          // deliberately unvalidated
        expected["\(c.name).key"] = c.expected
        print("wrote \(file.lastPathComponent): expects \(c.expected)")
    }
    expected["_template"] = url(from).lastPathComponent
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try (encoder.encode(expected) + Data([0x0A])).write(to: out.appendingPathComponent("expected.json"))
}

func runText(_ args: [String]) throws {
    guard let path = args.first else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(path))
    for component in document.store.components {
        for record in component.records {
            for (i, info) in record.info.messageInfos.enumerated() where info.type == 2001 && info.baseMessageIndex == nil {
                guard let storage = try? TSWP_StorageArchive(serializedBytes: record.payloads[i], extensions: Schema.extensions, partial: true) else { continue }
                let text = storage.text.joined()
                guard !text.isEmpty else { continue }
                print("\(record.identifier)\t\(text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\u{2029}", with: "¶"))")
            }
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage, code: 2) }
let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "inspect": try runInspect(rest)
    case "dump": try runDump(rest)
    case "roundtrip": try runRoundtrip(rest)
    case "verify": try runVerify(rest)
    case "snappy-check": try runSnappyCheck(rest)
    case "reference-strength": try runReferenceStrength(rest)
    case "text": try runText(rest)
    case "corpus":
        switch rest.first {
        case "add": try runCorpusAdd(Array(rest.dropFirst()))
        case "hostile": try runCorpusHostile(Array(rest.dropFirst()))
        default: fail(usage, code: 2)
        }
    case "version": print("deckmonkey \(DeckMonkey.version)")
    case "-h", "--help", "help": print(usage)
    default: fail(usage, code: 2)
    }
} catch IWAPackageError.unsupportedLegacyFormat(let path) {
    fail("refused: \(IWAPackageError.unsupportedLegacyFormat(path))", code: 3)
} catch {
    fail("error: \(error)")
}
