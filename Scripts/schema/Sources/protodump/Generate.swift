import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

/// Step 3 of the schema pipeline: SwiftProtobuf sources straight from the extracted descriptors.
///
/// No `protoc` and no `.proto` parsing: protoc-gen-swift is a plugin that reads a
/// `CodeGeneratorRequest` (descriptors plus a parameter string) on stdin, and the descriptors are
/// exactly what step 1 recovered. `google/protobuf/descriptor.proto` is passed as an import but
/// not generated: SwiftProtobuf already ships those types.
enum Generate {
    enum Failure: Error, CustomStringConvertible {
        case plugin(status: Int32, stderr: String)
        case reported(String)

        var description: String {
            switch self {
            case .plugin(let status, let stderr): return "protoc-gen-swift exited \(status): \(stderr)"
            case .reported(let message): return "protoc-gen-swift: \(message)"
            }
        }
    }

    static let external: Set<String> = ["google/protobuf/descriptor.proto"]

    static func run(descriptors: URL, plugin: URL, out: URL) throws -> [String] {
        let set = try Google_Protobuf_FileDescriptorSet(serializedBytes: Data(contentsOf: descriptors))
        var request = Google_Protobuf_Compiler_CodeGeneratorRequest()
        request.protoFile = set.file.map(withJSONNames)
        request.fileToGenerate = set.file.map(\.name).filter { !external.contains($0) }
        request.parameter = "Visibility=Public"

        // Kept in the temporary directory so a plugin failure can be replayed: plugin < request.pb
        let replay = FileManager.default.temporaryDirectory.appendingPathComponent("protodump-request.pb")
        try request.serializedData().write(to: replay)

        let process = Process()
        process.executableURL = plugin
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Write and read concurrently: the response can exceed a pipe buffer.
        let input = try request.serializedData()
        let writer = Thread { stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close() }
        writer.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.plugin(
                status: process.terminationStatus,
                stderr: String(decoding: errors, as: UTF8.self) + " (replay: \(plugin.path) < \(replay.path))")
        }
        let response = try Google_Protobuf_Compiler_CodeGeneratorResponse(serializedBytes: output)
        if response.hasError { throw Failure.reported(response.error) }

        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var written = [String]()
        for file in response.file {
            try Data(file.content.utf8).write(to: out.appendingPathComponent(file.name))
            written.append(file.name)
        }
        return written.sorted()
    }

    // MARK: Request normalization

    /// protoc fills `json_name` on every field before it calls a plugin, and protoc-gen-swift
    /// requires it; embedded descriptors do not carry it. Same rule as protoc's ToJsonName.
    static func withJSONNames(_ file: Google_Protobuf_FileDescriptorProto) -> Google_Protobuf_FileDescriptorProto {
        var file = file
        file.messageType = file.messageType.map(withJSONNames)
        file.extension = file.extension.map(withJSONName)
        return file
    }

    static func withJSONNames(_ message: Google_Protobuf_DescriptorProto) -> Google_Protobuf_DescriptorProto {
        var message = message
        message.field = message.field.map(withJSONName)
        message.extension = message.extension.map(withJSONName)
        message.nestedType = message.nestedType.map(withJSONNames)
        return message
    }

    static func withJSONName(_ field: Google_Protobuf_FieldDescriptorProto) -> Google_Protobuf_FieldDescriptorProto {
        guard !field.hasJsonName else { return field }
        var field = field
        var json = ""
        var capitalizeNext = false
        for c in field.name {
            if c == "_" {
                capitalizeNext = true
            } else if capitalizeNext {
                json += c.uppercased()
                capitalizeNext = false
            } else {
                json.append(c)
            }
        }
        field.jsonName = json
        return field
    }
}
