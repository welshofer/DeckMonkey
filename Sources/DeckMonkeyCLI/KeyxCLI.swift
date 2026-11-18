import DeckMonkey
import Foundation

enum KeyxCLI {
    static let usage = """
    usage: deckmonkey keyx <command> [options]

      inspect <file.keyx> [--slide <index>]
                            JSON: text, notes, tables, chart data, resources, fonts and warnings
      verify <file.keyx>     semantic diagnostics; not full JSON Schema or Keynote acceptance
      roundtrip <file.keyx> -o <out.keyx>
                            save, reopen and compare entry payloads; report added defaults
      notes <file.keyx> --slide <index> (--text <text> | --remove) -o <out.keyx>
                            replace the entire presenter-note value with plain text, or remove
                            it (absent, not JSON null); other slide content stays untouched
      from-ir <deck.json> -o <out.keyx> [--template <template.keyx>] [--size <W>x<H>]
              [--image <slide-id>=<image-path>]...
                            direct lectern.deck/1 authoring; images are local
                            PNG/JPEG/GIF bytes; --size cannot be combined with --template
      render <file.keyx> -o <dir> [--slide <index>]
                            approximate SVG previews, page-<n>.svg plus render.json warnings

    All slide indexes are 0-based. Every result identifies format "keyx".
    Output is Keynote Interchange, NOT native .key. No conversion or cloud service is used.
    Builds, transitions, Magic Move and comments remain native .key features.
    Imported documents are never projected through DeckIR. General text/object surgery is
    not a CLI operation; use the shared KeyxDocument value API for explicit document edits.

    Exit codes: 0 pass, 1 fail, 2 usage, 3 unsupported/refused.
    """

    static func run(_ args: [String]) throws {
        guard let command = args.first else { fail(usage, code: 2) }
        if ["help", "-h", "--help"].contains(command) {
            print(usage)
            return
        }
        let supported = ["inspect", "verify", "roundtrip", "notes", "from-ir", "render"]
        guard supported.contains(command) else {
            throw KeyxError.unsupported(
                "'keyx \(command)' is not supported. Use inspect, verify, roundtrip, notes, from-ir or render. "
                + "Native graph operations and .key/PPTX conversion are not interchange operations.")
        }
        guard args.count >= 2, !args[1].hasPrefix("-") else { fail(usage, code: 2) }
        let input = url(args[1])
        let rest = Array(args.dropFirst(2))
        switch command {
        case "inspect":
            let options = Options(rest, values: ["--slide"])
            let document = try DeckMonkey.openInterchange(input)
            let slides = try document.slides
            let indices = try slideIndices(options, count: slides.count)
            let size = try document.slideSize
            let issues = document.validate()
            var report = result(command, file: input)
            report["packageVersion"] = document.manifest["package_version"]?.string ?? "1.0"
            report["slideSize"] = ["width": size.width, "height": size.height]
            report["slideCount"] = slides.count
            report["entries"] = document.archiveEntryNames.filter { document.entryData(named: $0) != nil }
            report["slides"] = try indices.map { index -> [String: Any] in
                let summary = try document.inspectSlide(at: index)
                var row: [String: Any] = [
                    "index": index, "title": summary.title, "texts": summary.texts, "notes": summary.notes,
                    "tables": summary.tables, "shapeCounts": summary.shapeCounts,
                    "fonts": summary.fonts.sorted(), "warnings": summary.warnings,
                    "resources": summary.assets.map { ["filename": $0.filename, "bytes": $0.data.count] },
                    "charts": summary.charts.map { chart -> [String: Any] in
                        let values = chart.values.map { row in
                            row.map { value -> Any in
                                if let value { return value }
                                return NSNull()
                            }
                        }
                        return ["kind": chart.kind, "categories": chart.categories,
                                "seriesNames": chart.seriesNames, "values": values]
                    },
                ]
                if let identifier = slides[index].identifier { row["identifier"] = identifier }
                return row
            }
            report["diagnostics"] = diagnostics(issues)
            try printJSON(report)
            if issues.contains(where: { $0.severity == .error }) { fail("error: .keyx semantic validation failed") }
        case "verify":
            _ = Options(rest)
            let document = try DeckMonkey.openInterchange(input)
            let issues = document.validate()
            var report = result(command, file: input)
            report["scope"] = "semantic checks only; not full JSON Schema or native Keynote acceptance"
            report["valid"] = !issues.contains { $0.severity == .error }
            report["diagnostics"] = diagnostics(issues)
            try printJSON(report)
            if issues.contains(where: { $0.severity == .error }) { fail("error: .keyx semantic validation failed") }
        case "roundtrip":
            let options = Options(rest, values: ["-o"])
            let output = try outputURL(options)
            let comparison = try DeckMonkey.roundTripInterchange(input, to: output)
            var report = result(command, file: input)
            report["output"] = output.path
            report["comparison"] = "uncompressed entry bytes; ZIP encoding may differ"
            report["status"] = comparison.isIdentical ? "CLEAN" : comparison.preservesOriginalEntries ? "PRESERVED" : "DIFFERENT"
            report["identical"] = comparison.identical
            report["changed"] = comparison.changed
            report["removed"] = comparison.removed
            report["added"] = comparison.added
            try printJSON(report)
            if !comparison.preservesOriginalEntries { fail("error: .keyx entry payloads changed") }
        case "notes":
            let options = Options(rest, values: ["--slide", "--text", "-o"], flags: ["--remove"])
            guard options.value("--slide") != nil,
                  (options.value("--text") != nil) != options.contains("--remove") else {
                fail("error: notes requires --slide and exactly one of --text or --remove\n\n\(usage)", code: 2)
            }
            let output = try outputURL(options)
            var document = try DeckMonkey.openInterchange(input)
            let indices = try slideIndices(options, count: document.slides.count)
            let index = indices[0]
            try document.editSlide(at: index) { slide in
                if let text = options.value("--text") { slide.setNote(.value(KeyxText(text))) }
                else { slide.setNote(.inherited) }
            }
            try document.save(to: output)
            var report = result(command, file: input)
            report["output"] = output.path
            report["slide"] = index
            report["edit"] = options.contains("--remove") ? "remove-note-property" : "replace-note-with-plain-text"
            report["diagnostics"] = diagnostics(document.validate())
            try printJSON(report)
        case "from-ir":
            let options = Options(rest, values: ["-o", "--template", "--size", "--image"], repeated: ["--image"])
            let output = try outputURL(options)
            let ir = try JSONDecoder().decode(DeckIR.self, from: Data(contentsOf: input))
            let template = try options.value("--template").map { try DeckMonkey.openInterchange(url($0)) }
            var authoringOptions = KeyxAuthoringOptions()
            if let size = options.value("--size") {
                guard template == nil else { fail("error: --size cannot override a .keyx template's size", code: 2) }
                let parts = size.lowercased().split(separator: "x", omittingEmptySubsequences: false)
                guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
                      width.isFinite, height.isFinite else { fail("error: --size takes <width>x<height> in points", code: 2) }
                authoringOptions.width = width
                authoringOptions.height = height
            }
            var images: [String: Data] = [:]
            let slideIDs = Set(ir.slides.map(\.id))
            for binding in options.all("--image") {
                guard let separator = binding.firstIndex(of: "=") else {
                    fail("error: --image takes <slide-id>=<image-path>", code: 2)
                }
                let id = String(binding[..<separator])
                let path = String(binding[binding.index(after: separator)...])
                guard slideIDs.contains(id), images[id] == nil, !path.isEmpty else {
                    fail("error: --image needs a unique, existing IR slide ID and a nonempty image path", code: 2)
                }
                images[id] = try Data(contentsOf: url(path))
            }
            let authored = try KeyxAuthor.render(ir, options: authoringOptions, images: images, template: template)
            try authored.document.save(to: output)
            var report = result(command, file: input)
            report["output"] = output.path
            report["slideCount"] = try authored.document.slides.count
            report["slideGroups"] = authored.slideGroups
            report["warnings"] = authored.warnings
            report["diagnostics"] = diagnostics(authored.document.validate())
            try printJSON(report)
        case "render":
            let options = Options(rest, values: ["-o", "--slide"], flags: ["--stages"])
            guard !options.contains("--stages") else {
                throw KeyxError.unsupported("Interchange has no build stages, transitions or Magic Move. Use the native .key backend.")
            }
            let output = url(options.require("-o"))
            let document = try DeckMonkey.openInterchange(input)
            let issues = document.validate()
            let errors = issues.filter { $0.severity == .error }
            guard errors.isEmpty else { throw KeyxError.validation(errors) }
            let indices = try slideIndices(options, count: document.slides.count)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var pages: [[String: Any]] = []
            for index in indices {
                let preview = try KeyxPreviewRenderer.render(document, slideAt: index)
                let name = "page-\(index + 1).svg"
                try Data(preview.svg.utf8).write(to: output.appendingPathComponent(name), options: .atomic)
                pages.append(["index": index, "file": name, "width": preview.width, "height": preview.height,
                              "warnings": preview.warnings])
            }
            var report = result(command, file: input)
            report["output"] = output.path
            report["approximate"] = true
            report["slides"] = pages
            report["diagnostics"] = diagnostics(issues)
            try json(report).write(to: output.appendingPathComponent("render.json"), options: .atomic)
            try printJSON(report)
        default:
            fail(usage, code: 2)
        }
    }

    private static func result(_ command: String, file: URL) -> [String: Any] {
        ["format": "keyx", "formatName": "Keynote Interchange (ZIP/JSON)", "command": command, "file": file.path]
    }

    private static func diagnostics(_ issues: [KeyxDiagnostic]) -> [[String: String]] {
        issues.map { ["severity": $0.severity.rawValue, "path": $0.path, "message": $0.message] }
    }

    private static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func printJSON(_ value: [String: Any]) throws {
        FileHandle.standardOutput.write(try json(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func outputURL(_ options: Options) throws -> URL {
        let output = url(options.require("-o"))
        guard output.pathExtension.lowercased() == "keyx" else {
            throw KeynoteFormatError.expectedInterchange(path: output.path)
        }
        return output
    }

    private static func slideIndices(_ options: Options, count: Int) throws -> [Int] {
        guard let value = options.value("--slide") else { return Array(0..<count) }
        guard let index = Int(value) else { fail("error: --slide requires a 0-based integer", code: 2) }
        guard index >= 0, index < count else { throw KeyxError.invalid("No .keyx slide at index \(index) (count \(count))") }
        return [index]
    }

    private struct Options {
        private var values: [String: [String]] = [:]

        init(_ args: [String], values: Set<String> = [], flags: Set<String> = [], repeated: Set<String> = []) {
            var index = 0
            while index < args.count {
                let name = args[index]
                guard values.contains(name) || flags.contains(name) else {
                    fail("error: unexpected .keyx option or argument \(name)\n\n\(usage)", code: 2)
                }
                guard self.values[name] == nil || repeated.contains(name) else {
                    fail("error: duplicate option \(name)", code: 2)
                }
                if flags.contains(name) {
                    self.values[name] = []
                    index += 1
                } else {
                    guard index + 1 < args.count,
                          !args[index + 1].hasPrefix("-") || args[index + 1].dropFirst().first?.isNumber == true else {
                        fail("error: \(name) needs a value", code: 2)
                    }
                    self.values[name, default: []].append(args[index + 1])
                    index += 2
                }
            }
        }

        func contains(_ name: String) -> Bool { values[name] != nil }
        func value(_ name: String) -> String? { values[name]?.first }
        func all(_ name: String) -> [String] { values[name] ?? [] }
        func require(_ name: String) -> String {
            guard let value = value(name) else { fail("error: \(name) is required\n\n\(usage)", code: 2) }
            return value
        }
    }
}
