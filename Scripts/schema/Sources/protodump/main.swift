import Foundation
import SwiftProtobuf

// protodump — docs/spec.md §7 steps 1–3.
//
// usage: protodump extract <Keynote.app> --out <dir>
//          Writes <dir>/descriptors.pb (a FileDescriptorSet in dependency order: what generation
//          reads) and <dir>/*.proto (rendered, for people and schema-diff). Exit 1 when
//          nothing is found, a dependency is missing, or two binaries disagree about a file.
//        protodump generate <descriptors.pb> --plugin <protoc-gen-swift> --out <dir>
//          Runs protoc-gen-swift on the descriptors (Visibility=Public) and writes its files.
//        protodump dispatch <descriptors.pb> <registry.json> <generated dir> --out <Dispatch.swift>
//          Emits the type-number switch and the union of the generated extension maps.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
    usage: protodump extract <Keynote.app> --out <dir>
           protodump generate <descriptors.pb> --plugin <protoc-gen-swift> --out <dir>
           protodump dispatch <descriptors.pb> <registry.json> <generated dir> --out <Dispatch.swift>
    """

func option(_ flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail(usage, code: 2) }
    return args[i + 1]
}

func extract(app: URL, out: URL) throws {
    let found = try Extract.all(inApp: app)
    guard !found.isEmpty else { fail("no descriptors found in \(app.path)") }

    // Dependency order, so a reader (and protoc-gen-swift) sees every import before its user.
    let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.descriptor.name, $0) })
    var ordered = [Extract.Found]()
    var visited = Set<String>()
    var missing = Set<String>()
    func visit(_ name: String) {
        guard !visited.contains(name) else { return }
        visited.insert(name)
        guard let item = byName[name] else { missing.insert(name); return }
        item.descriptor.dependency.forEach(visit)
        ordered.append(item)
    }
    found.map(\.descriptor.name).forEach(visit)
    guard missing.isEmpty else { fail("missing dependencies: \(missing.sorted().joined(separator: ", "))") }

    var set = Google_Protobuf_FileDescriptorSet()
    set.file = ordered.map(\.descriptor)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try set.serializedData().write(to: out.appendingPathComponent("descriptors.pb"))
    for item in ordered where !Generate.external.contains(item.descriptor.name) {
        let text = Render.file(item.descriptor, source: item.binary)
        try Data(text.utf8).write(to: out.appendingPathComponent(item.descriptor.name))
    }
    for item in ordered {
        let d = item.descriptor
        print("\(d.name)  package \(d.package)  messages \(d.messageType.count)  enums \(d.enumType.count)  extensions \(d.extension.count)  [\(item.binary)]")
    }
    print("protodump: \(ordered.count) files → \(out.appendingPathComponent("descriptors.pb").path)")
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "extract":
        guard args.count >= 2, let out = option("--out", in: args) else { fail(usage, code: 2) }
        try extract(app: URL(fileURLWithPath: args[1]), out: URL(fileURLWithPath: out))
    case "generate":
        guard args.count >= 2, let plugin = option("--plugin", in: args), let out = option("--out", in: args) else {
            fail(usage, code: 2)
        }
        let files = try Generate.run(
            descriptors: URL(fileURLWithPath: args[1]), plugin: URL(fileURLWithPath: plugin), out: URL(fileURLWithPath: out))
        print("generate: \(files.count) Swift files → \(out)")
    case "dispatch":
        guard args.count >= 4, let out = option("--out", in: args) else { fail(usage, code: 2) }
        let count = try DispatchTable.run(
            descriptors: URL(fileURLWithPath: args[1]), registry: URL(fileURLWithPath: args[2]),
            generated: URL(fileURLWithPath: args[3]), out: URL(fileURLWithPath: out))
        print("dispatch: \(count) types → \(out)")
    default:
        fail(usage, code: 2)
    }
} catch {
    fail("protodump: \(error)")
}
