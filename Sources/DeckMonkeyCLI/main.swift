import DeckMonkey
import Foundation
import SwiftProtobuf

// deckmonkey — the acceptance surface (docs/spec.md §13). Every gate is one of these subcommands
// with a machine-readable exit code: 0 pass, 1 fail, 2 usage error, 3 refused by design (a
// Keynote '09 APXL file: out of scope, docs/spec.md §2, so neither a pass nor a failure).

enum CLI {
    static let usage = """
    usage: deckmonkey <command> [options]

      inspect <file>                 components, object counts, type histogram, versions
      dump <file> [component]        every record: identifier, types, versions, lengths, references
      render <file> -o <dir> [--slide <index>] [--fonts <dir>]...
                                     track R: each slide as SVG (<dir>/page-<n>.svg in PDF page
                                     order, skipped slides as skipped-<index>.svg) and a JSON report
                                     of what could not be drawn; --fonts indexes every .ttf, .otf
                                     and .ttc under a directory for text measurement (default on
                                     macOS: the system's font directories)
      object <file> --slide <index>  the slide's drawables: id, kind, frame, text runs (JSON)
      object <file> --object <id> --frame <x,y,w,h> -o <out.key>
                                     move or resize a shape, text box, placeholder, image or movie
                                     (unrotated, on a slide); paths and masks scale with it
      object <file> --object <id> --delete -o <out.key>
                                     delete a shape, text box, image, movie, group or line and
                                     everything only it used
      insert <file> --slide <index> (--text <s> | --image <path>) --frame <x,y,w,h> -o <out.key>
                                     a new text box (h 0: height follows the text; y is its
                                     vertical centre) or picture, from the bundled parts, in the
                                     deck's own default styles
      parts <file> --object <id>... -o <out.keyparts>
                                     a parts package: those drawables, what only they use, and
                                     the styles they point at (no slides, theme or data)
      record <file> <id>...          each record's payloads decoded as protobuf text format
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
      text <file> [--tables]         every TSWP text storage: identifier and its text (¶ = paragraph
                                     break); --tables adds each offset table (index→object id)
      replace <file> --find <s> --replace <s> [--storage <id>] -o <out.key>
                                     replace every occurrence (Phase 1: within a paragraph; the new
                                     text takes the style in force at the first replaced character;
                                     overlapping hyperlinks and smart fields are removed and listed)
      locate <file> --storage <id> | --object <id>
                                     a text storage's (or image's, shape's) PDF page and frame, as JSON
      data <file>                    every DataInfo: identifier, file in Data/, size, digest, the
                                     objects that refer to it, and any Data/ file nothing describes
      image <file> --list            every image object: identifier, its file, page
      image <file> --object <id> --with <path> -o <out.key>
                                     replace an image's pixels (PNG, JPEG, GIF, TIFF); the frame is
                                     kept; data nothing refers to any more is removed with its file
      media <file> --list            every movie and audio clip: identifier, its file, page
      media <file> --object <id> --with <path> [--poster <image>] -o <out.key>
                                     replace a movie's or audio clip's media (MPEG-4/QuickTime);
                                     a movie needs a poster image; the frame is kept
      slide list <file>              the slides in show order: index, node, slide, component
      slide move <file> --index <n> --to <m> -o <out.key>
      slide delete <file> --index <n> -o <out.key>
      slide clone <file> --index <n> [--to <m>] -o <out.key>
      slide masters <file>           the deck's masters: index, identifier, name
      slide new <file> --master <name>[|<name>...] [--to <m>] -o <out.key>
                                     new slides on masters, as Keynote's New Slide makes them
      slide import <file> --from <source.key> --index <n> [--to <m>] -o <out.key>
      from-ir <deck.json> --template <t.key> [--parts <deck.key>]... [--plan-out <plan.json>] -o <out.key>
                                     build a .key from a lectern.deck/1 Deck IR on a template's masters
                                     move, delete or duplicate a slide (0-based indexes, show order);
                                     delete removes the slide's component and data only it used; a
                                     clone goes after its source unless --to says where
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
    // A value may be a negative number ("-91,-102,1053,630"), never another flag.
    guard i + 1 < args.count, !args[i + 1].hasPrefix("-") || args[i + 1].dropFirst().first?.isNumber == true else {
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
    print("pdf pages: \(document.pageOfSlide.count) (non-skipped slides in slide-tree order)")
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

func runRender(_ args: [String]) throws {
    guard let path = args.first, let out = option("-o", in: args) else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(path))
    var fontDirectories = [String]()
    var i = 0
    while i < args.count { if args[i] == "--fonts", i + 1 < args.count { fontDirectories.append(args[i + 1]); i += 1 }; i += 1 }
    // Without --fonts on a Mac, the system's own fonts.
    #if os(macOS)
    let directories = fontDirectories.isEmpty ? RenderFonts.macOSFontDirectories : fontDirectories.map { url($0) }
    #else
    let directories = fontDirectories.map { url($0) }
    #endif
    let fonts = RenderFonts.library(directories: directories)
    let renderer = KeynoteRenderer(document: document, fonts: fonts)
    let directory = url(out)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var slides = try renderer.renderAll().enumerated().map { ($0.offset, $0.element) }
    if let only = option("--slide", in: args) {
        guard let index = Int(only), slides.indices.contains(index) else { fail("error: no slide \(only)") }
        slides = [slides[index]]
    }
    var report = [[String: Any]]()
    for (index, entry) in slides {
        let name = entry.page.map { "page-\($0).svg" } ?? "skipped-\(index).svg"
        try Data(entry.rendered.svg.utf8).write(to: directory.appendingPathComponent(name))
        report.append(["index": index, "slide": entry.slide, "page": entry.page as Any, "file": name, "problems": entry.rendered.problems])
    }
    let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: directory.appendingPathComponent("render.json"))
    let problems = Set(slides.flatMap { $0.1.rendered.problems }).sorted()
    print("rendered \(slides.count) slide(s) to \(directory.path)" + (problems.isEmpty ? "" : "; not drawn: " + problems.joined(separator: ", ")))
}

func runObject(_ args: [String]) throws {
    guard let path = args.first else { fail(CLI.usage, code: 2) }
    var document = try DeckMonkey.open(url(path))
    if let index = option("--slide", in: args) {
        let order = document.slideOrder()
        guard let i = Int(index), order.indices.contains(i) else { fail("error: no slide \(index)") }
        let items: [[String: Any]] = KeynoteRenderer(document: document).drawables(onSlide: order[i].slide).map { d in
            ["id": d.id, "kind": d.kind.rawValue, "name": d.name, "frame": [d.x, d.y, d.width, d.height], "angle": d.angle,
             "runs": d.runs.map { ["paragraph": $0.paragraph, "run": $0.run, "text": $0.text, "range": [$0.range.lowerBound, $0.range.upperBound]] }]
        }
        let json = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        return
    }
    if args.contains("--delete"), let idText = option("--object", in: args), let id = UInt64(idText), let out = option("-o", in: args) {
        let report = try document.deleteDrawable(id)
        try document.save(to: url(out))
        print("deleted object \(id): \(report.removedObjects) objects, \(report.removedData.count) data")
        return
    }
    guard let idText = option("--object", in: args), let id = UInt64(idText), let frameText = option("--frame", in: args),
          let out = option("-o", in: args) else { fail(CLI.usage, code: 2) }
    let v = frameText.split(separator: ",").compactMap { Double($0) }
    guard v.count == 4 else { fail("error: --frame takes x,y,width,height") }
    try document.setDrawableFrame(id, .init(x: v[0], y: v[1], width: v[2], height: v[3]))
    try document.save(to: url(out))
    print("placed object \(id) at \(frameText)")
}

func runInsert(_ args: [String]) throws {
    guard let path = args.first, let out = option("-o", in: args), let index = option("--slide", in: args).flatMap(Int.init),
          let frameText = option("--frame", in: args) else { fail(CLI.usage, code: 2) }
    var document = try DeckMonkey.open(url(path))
    let order = document.slideOrder()
    guard order.indices.contains(index) else { fail("error: no slide \(index)") }
    let v = frameText.split(separator: ",").compactMap { Double($0) }
    guard v.count == 4 else { fail("error: --frame takes x,y,width,height") }
    let frame = KeynoteDocument.Frame(x: v[0], y: v[1], width: v[2], height: v[3])
    let id: UInt64
    if let text = option("--text", in: args) {
        id = try document.insertTextBox(onto: order[index].slide, frame: frame, text: text)
    } else if let image = option("--image", in: args) {
        id = try document.insertImage(Data(contentsOf: url(image)), preferredFileName: (image as NSString).lastPathComponent, onto: order[index].slide, frame: frame)
    } else { fail(CLI.usage, code: 2) }
    try document.save(to: url(out))
    print("inserted object \(id) on slide \(index)")
}

func runParts(_ args: [String]) throws {
    guard let path = args.first, let out = option("-o", in: args) else { fail(CLI.usage, code: 2) }
    var ids = [UInt64]()
    var i = 0
    while i < args.count { if args[i] == "--object", i + 1 < args.count, let id = UInt64(args[i + 1]) { ids.append(id); i += 1 }; i += 1 }
    guard !ids.isEmpty else { fail(CLI.usage, code: 2) }
    let package = try DeckMonkey.open(url(path)).partsPackage(drawables: ids)
    let data = try package.zipData()
    try data.write(to: url(out))
    print("parts: \(ids.count) drawable(s), \(data.count) bytes")
}

func runRecord(_ args: [String]) throws {
    guard args.count >= 2 else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(args[0]))
    for id in args.dropFirst() {
        guard let identifier = UInt64(id), let record = document.store.record(for: identifier) else { fail("error: no record \(id)") }
        print("# \(identifier) in \(document.store.entry(for: identifier)?.component ?? "?")")
        for (info, payload) in zip(record.info.messageInfos, record.payloads) {
            let name = document.registry?.name(for: info.type) ?? "type \(info.type)"
            guard let type = Schema.messageType(for: info.type),
                  let message = try? type.init(serializedBytes: payload, extensions: Schema.extensions, partial: true) else {
                print("## \(name): \(payload.count) bytes, not decoded"); continue
            }
            print("## \(name)")
            print(message.textFormatString())
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
    let tables = args.contains("--tables")
    guard let path = args.first(where: { !$0.hasPrefix("--") }) else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(path))
    for component in document.store.components {
        for record in component.records {
            for (i, info) in record.info.messageInfos.enumerated() where info.type == 2001 && info.baseMessageIndex == nil {
                guard let storage = try? TSWP_StorageArchive(serializedBytes: record.payloads[i], extensions: Schema.extensions, partial: true) else { continue }
                let text = storage.text.joined()
                guard !text.isEmpty else { continue }
                let shown = text.replacingOccurrences(of: "\r", with: "¶").replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\u{2029}", with: "¶")
                print("\(record.identifier)\t\(shown)")
                if tables {
                    if storage.text.count != 1 { print("    text: \(storage.text.count) strings") }
                    for (name, entries) in TextOffsets.tables(of: storage) where !entries.isEmpty {
                        print("    \(name): " + entries.map { "\($0.index)\($0.object.map { "→\($0)" } ?? "")" }.joined(separator: " "))
                    }
                }
            }
        }
    }
}

func runReplace(_ args: [String]) throws {
    guard let path = args.first, !path.hasPrefix("-"),
          let needle = option("--find", in: args), let replacement = option("--replace", in: args),
          let out = option("-o", in: args) else { fail(CLI.usage, code: 2) }
    let storage = option("--storage", in: args).map { value -> UInt64 in
        guard let id = UInt64(value) else { fail("error: --storage needs an object identifier", code: 2) }
        return id
    }
    var document = try DeckMonkey.open(url(path))
    let summary = try document.replaceAll(needle, with: replacement, in: storage)
    guard summary.replacements > 0 else { fail("error: \"\(needle)\" not found") }
    try FileManager.default.createDirectory(at: url(out).deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.save(to: url(out))
    print("replaced \(summary.replacements) occurrence(s) in \(summary.storages.count) storage(s): \(summary.storages.map(String.init).joined(separator: ", "))")
    if !summary.removedFields.isEmpty {
        print("removed \(summary.removedFields.count) overlapping field(s): \(summary.removedFields.map(String.init).joined(separator: ", "))")
    }
    print("output: \(url(out).path)")
}

func runLocate(_ args: [String]) throws {
    guard let path = args.first, !path.hasPrefix("-") else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(path))
    func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
    if let value = option("--object", in: args), let id = UInt64(value) {
        guard let at = document.location(ofDrawable: id) else { fail("error: \(id) is not an image or shape") }
        let frame = at.frame.map { "{\"x\":\(num($0.x)),\"y\":\(num($0.y)),\"width\":\(num($0.width)),\"height\":\(num($0.height)),\"angle\":\(num($0.angle))}" } ?? "null"
        let e = document.mediaEffects(ofImage: id)
        print("{\"object\":\(id),\"slide\":\(at.slide.map(String.init) ?? "null"),\"page\":\(at.page.map(String.init) ?? "null"),\"frame\":\(frame),\"reflection\":\(e.reflection),\"shadow\":\(e.shadow),\"stroke\":\(e.stroke)}")
        return
    }
    guard let value = option("--storage", in: args), let id = UInt64(value) else { fail(CLI.usage, code: 2) }
    // Text no slide shape owns (presenter notes, table cells, masters) is not on a page by itself.
    guard let at = document.location(of: id) else {
        print("{\"storage\":\(id),\"shape\":null,\"slide\":null,\"page\":null,\"frame\":null}")
        return
    }
    let frame = at.frame.map { "{\"x\":\(num($0.x)),\"y\":\(num($0.y)),\"width\":\(num($0.width)),\"height\":\(num($0.height)),\"angle\":\(num($0.angle))}" } ?? "null"
    print("{\"storage\":\(id),\"shape\":\(at.shape),\"slide\":\(at.slide.map(String.init) ?? "null"),\"page\":\(at.page.map(String.init) ?? "null"),\"frame\":\(frame)}")
}

func runData(_ args: [String]) throws {
    guard let path = args.first else { fail(CLI.usage, code: 2) }
    let document = try DeckMonkey.open(url(path))
    guard let metadata = document.packageMetadata else { fail("error: no PackageMetadata") }
    var referrers = [UInt64: [UInt64]]()
    for component in document.store.components {
        for record in component.records {
            for info in record.info.messageInfos {
                for id in info.dataReferences { referrers[id, default: []].append(record.identifier) }
            }
        }
    }
    var described = Set<String>()
    for d in metadata.datas.sorted(by: { $0.identifier < $1.identifier }) {
        let name = d.storedFileName ?? d.preferredFileName
        described.insert("Data/" + name)
        let bytes = document.package.data("Data/" + name)
        let digest = d.digest.map { String(format: "%02x", $0) }.joined()
        let attrs = d.hasAttributes ? " attributes \(d.attributes.textFormatString().replacingOccurrences(of: "\n", with: " "))" : ""
        print("\(d.identifier)\t\(name)\t\(bytes.map { "\($0.count) bytes" } ?? "MISSING")\tdigest \(digest) (\(d.digest.count) bytes)\tpreferred \(d.preferredFileName)\treferrers \(referrers[d.identifier]?.map(String.init).joined(separator: ",") ?? "none")\(attrs)")
    }
    for name in document.package.dataNames.sorted() where !described.contains(name) {
        print("UNDESCRIBED\t\(name)")
    }
}

func runImage(_ args: [String]) throws {
    guard let path = args.first, !path.hasPrefix("-") else { fail(CLI.usage, code: 2) }
    var document = try DeckMonkey.open(url(path))
    if args.contains("--list") {
        let datas = Dictionary(uniqueKeysWithValues: (document.packageMetadata?.datas ?? []).map { ($0.identifier, $0) })
        let pages = document.pageOfSlide
        for id in document.images {
            guard let image = try? TSD_ImageArchive(serializedBytes: document.store.record(for: id)!.payloads[0], extensions: Schema.extensions, partial: true) else { continue }
            let data = image.hasData ? datas[image.data.identifier] : nil
            let name = data.map { $0.storedFileName ?? "(app resource) " + $0.preferredFileName } ?? "-"
            let parent = image.super.hasParent ? image.super.parent.identifier : 0
            print("\(id)\t\(name)\tpage \(pages[parent].map(String.init) ?? "-")")
        }
        return
    }
    guard let value = option("--object", in: args), let id = UInt64(value), let with = option("--with", in: args),
          let out = option("-o", in: args) else { fail(CLI.usage, code: 2) }
    let bytes = try Data(contentsOf: url(with))
    let report = try document.replaceImage(id, with: bytes, preferredFileName: url(with).lastPathComponent)
    try FileManager.default.createDirectory(at: url(out).deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.save(to: url(out))
    print("replaced image \(id): Data/\(report.fileName) (data \(report.newData))")
    if !report.removedData.isEmpty {
        print("removed data \(report.removedData.map(String.init).joined(separator: ", ")) and files \(report.removedFiles.joined(separator: ", "))")
    }
    print("output: \(url(out).path)")
}

func runMedia(_ args: [String]) throws {
    guard let path = args.first, !path.hasPrefix("-") else { fail(CLI.usage, code: 2) }
    var document = try DeckMonkey.open(url(path))
    if args.contains("--list") {
        let datas = Dictionary(uniqueKeysWithValues: (document.packageMetadata?.datas ?? []).map { ($0.identifier, $0) })
        let pages = document.pageOfSlide
        for id in document.movies {
            guard let m = try? TSD_MovieArchive(serializedBytes: document.store.record(for: id)!.payloads[0], extensions: Schema.extensions, partial: true) else { continue }
            let name = m.hasMovieData ? (datas[m.movieData.identifier]?.storedFileName ?? "-") : (m.isLiveVideo ? "(live video placeholder)" : "-")
            let parent = m.super.hasParent ? m.super.parent.identifier : 0
            print("\(id)\t\(m.audioOnly ? "audio" : "movie")\t\(name)\t\(String(format: "%.2fs", m.endTime))\tpage \(pages[parent].map(String.init) ?? "-")")
        }
        return
    }
    guard let value = option("--object", in: args), let id = UInt64(value), let with = option("--with", in: args),
          let out = option("-o", in: args) else { fail(CLI.usage, code: 2) }
    let poster = try option("--poster", in: args).map { try Data(contentsOf: url($0)) }
    let report = try document.replaceMedia(id, with: try Data(contentsOf: url(with)), preferredFileName: url(with).lastPathComponent, poster: poster)
    try FileManager.default.createDirectory(at: url(out).deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.save(to: url(out))
    print("replaced \(id): Data/\(report.fileName) (\(String(format: "%.2f", report.duration)) s)\(report.posterFileName.map { ", poster Data/\($0)" } ?? "")")
    if !report.removedData.isEmpty {
        print("removed data \(report.removedData.map(String.init).joined(separator: ", ")) and files \(report.removedFiles.joined(separator: ", "))")
    }
    print("output: \(url(out).path)")
}

func runFromIR(_ args: [String]) throws {
    guard let path = args.first, !path.hasPrefix("-"), let template = option("--template", in: args), let out = option("-o", in: args) else {
        fail(CLI.usage, code: 2)
    }
    let ir = try JSONDecoder().decode(DeckIR.self, from: Data(contentsOf: url(path)))
    let base = try DeckMonkey.open(url(template))
    // New shapes, text boxes, charts and tables are copied from parts decks of Keynote-made drawables.
    var partsPaths = [String](), i = 0
    while i < args.count { if args[i] == "--parts", i + 1 < args.count { partsPaths.append(args[i + 1]); i += 2 } else { i += 1 } }
    if partsPaths.isEmpty { partsPaths = ["Corpus/features/drawables.key", "Corpus/features/charts.key", "Corpus/features/tables-parts.key"] }
    let parts = try partsPaths.filter { FileManager.default.fileExists(atPath: url($0).path) }.map { try DeckMonkey.open(url($0)) }
    let plan = try DeckIRWriter.plan(ir, template: base, parts: parts)
    if let planOut = option("--plan-out", in: args) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: url(planOut))
    }
    let (document, report) = try DeckIRWriter.apply(plan, template: base, parts: parts)
    try FileManager.default.createDirectory(at: url(out).deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.save(to: url(out))
    print("built \(report.slides.count) slide(s) on \(Set(report.slides.map(\.master)).count) master(s)"
        + (report.ignored.isEmpty ? "" : "; no place for: \(report.ignored.joined(separator: ", "))"))
    print("output: \(url(out).path)")
}

func runSlide(_ args: [String]) throws {
    guard let verb = args.first, args.count >= 2, !args[1].hasPrefix("-") else { fail(CLI.usage, code: 2) }
    var document = try DeckMonkey.open(url(args[1]))
    if verb == "list" {
        for (i, s) in try document.slideList().enumerated() {
            print("\(i)\tnode \(s.node)\tslide \(s.slide)\t\(s.component)\(s.skipped ? "\tskipped" : "")")
        }
        return
    }
    if verb == "masters" {
        for (i, m) in document.masters().enumerated() { print("\(i)\t\(m.id)\t\(m.name)") }
        return
    }
    if verb == "new" {
        guard let out = option("-o", in: args), let wanted = option("--master", in: args) else { fail(CLI.usage, code: 2) }
        // One or more master names, separated by "|", each added in turn at the end (or at --to).
        var at = option("--to", in: args).flatMap(Int.init)
        for name in wanted.split(separator: "|").map(String.init) {
            guard let master = document.masters().first(where: { $0.name == name }) else { fail("error: no master named \(name)") }
            let report = try document.addSlide(fromMaster: master.id, at: at)
            if let a = at { at = a + 1 }
            print("added slide \(report.slide) on \(name) in \(report.component)")
        }
        try document.save(to: url(out))
        return
    }
    guard let i = option("--index", in: args).flatMap(Int.init), let out = option("-o", in: args) else { fail(CLI.usage, code: 2) }
    switch verb {
    case "move":
        guard let to = option("--to", in: args).flatMap(Int.init) else { fail(CLI.usage, code: 2) }
        try document.moveSlide(from: i, to: to)
        print("moved slide \(i) to \(to)")
    case "clone":
        let report = try document.cloneSlide(at: i, to: option("--to", in: args).flatMap(Int.init))
        print("cloned slide \(i) (\(report.source)) as \(report.slide) in \(report.component): \(report.copiedObjects) objects")
    case "import":
        guard let from = option("--from", in: args) else { fail(CLI.usage, code: 2) }
        let source = try DeckMonkey.open(url(from))
        let report = try document.importSlide(at: i, from: source, to: option("--to", in: args).flatMap(Int.init))
        print("imported slide \(i) (\(report.source)) of \(from) as \(report.slide) in \(report.component): \(report.copiedObjects) objects, "
            + "\(report.mappedObjects) references mapped to this deck, \(report.copiedData) data copied, \(report.sharedData) shared")
    case "delete":
        let report = try document.deleteSlide(at: i)
        print("deleted slide \(i) (\(report.slide), \(report.component)): \(report.removedObjects) objects"
            + (report.removedFiles.isEmpty ? "" : ", files \(report.removedFiles.joined(separator: ", "))"))
    default:
        fail(CLI.usage, code: 2)
    }
    try FileManager.default.createDirectory(at: url(out).deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.save(to: url(out))
    print("output: \(url(out).path)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage, code: 2) }
let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "inspect": try runInspect(rest)
    case "dump": try runDump(rest)
    case "record": try runRecord(rest)
    case "parts": try runParts(rest)
    case "insert": try runInsert(rest)
    case "object": try runObject(rest)
    case "render": try runRender(rest)
    case "roundtrip": try runRoundtrip(rest)
    case "verify": try runVerify(rest)
    case "snappy-check": try runSnappyCheck(rest)
    case "reference-strength": try runReferenceStrength(rest)
    case "text": try runText(rest)
    case "replace": try runReplace(rest)
    case "locate": try runLocate(rest)
    case "data": try runData(rest)
    case "image": try runImage(rest)
    case "media": try runMedia(rest)
    case "slide": try runSlide(rest)
    case "from-ir": try runFromIR(rest)
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
