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
    case "version": print("deckmonkey \(DeckMonkey.version)")
    case "-h", "--help", "help": print(usage)
    default: fail(usage, code: 2)
    }
} catch IWAPackageError.unsupportedLegacyFormat(let path) {
    fail("refused: \(IWAPackageError.unsupportedLegacyFormat(path))", code: 3)
} catch {
    fail("error: \(error)")
}
