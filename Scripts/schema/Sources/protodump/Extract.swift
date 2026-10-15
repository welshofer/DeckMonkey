import Foundation
import SwiftProtobuf

/// Step 1 of the schema pipeline: recover serialized `FileDescriptorProto`s from Mach-O files.
///
/// protobuf's C++ generator embeds each `.proto` file's descriptor as a byte array that begins
/// with field 1 (`name`, tag 0x0A), a varint length, then the file name. So: find every
/// `.proto` suffix, step back over the name to its length varint and the 0x0A tag, then walk
/// the wire format forward while tags stay valid for `FileDescriptorProto`. The walk's end is
/// the blob's end. Every candidate must decode with SwiftProtobuf and carry the name it was
/// found by; anything else is noise (a `.proto` string that is a dependency name, a log string).
enum Extract {
    struct Found {
        var descriptor: Google_Protobuf_FileDescriptorProto
        var bytes: Data
        var binary: String
    }

    enum Failure: Error, CustomStringConvertible {
        case conflictingDescriptors(name: String, first: String, second: String)

        var description: String {
            switch self {
            case .conflictingDescriptors(let name, let first, let second):
                return "\(name): different descriptors in \(first) and \(second)"
            }
        }
    }

    /// Field numbers and wire types of `google.protobuf.FileDescriptorProto`.
    static let fileDescriptorFields: [Int: Int] = [
        1: 2, 2: 2, 3: 2, 4: 2, 5: 2, 6: 2, 7: 2, 8: 2, 9: 2, 10: 0, 11: 0, 12: 2, 13: 2, 14: 0,
    ]

    static func scan(_ url: URL) throws -> [Found] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let bytes = [UInt8](data)
        let suffix = Array(".proto".utf8)
        var found = [Found]()
        var i = suffix.count
        while i <= bytes.count {
            defer { i += 1 }
            guard bytes[i - 1] == suffix[5], Array(bytes[(i - suffix.count)..<i]) == suffix else { continue }
            // Candidate name lengths: the name ends at i; try each plausible start.
            for nameLength in suffix.count...min(255, i - 2) {
                let nameStart = i - nameLength
                // One-byte length varint (names are < 128 bytes) preceded by the 0x0A tag.
                guard nameLength < 128, nameStart >= 2,
                      bytes[nameStart - 1] == UInt8(nameLength), bytes[nameStart - 2] == 0x0A else { continue }
                let start = nameStart - 2
                guard let end = walk(bytes, from: start) else { continue }
                let blob = Data(bytes[start..<end])
                guard let descriptor = try? Google_Protobuf_FileDescriptorProto(serializedBytes: blob),
                      descriptor.name == String(decoding: bytes[nameStart..<i], as: UTF8.self),
                      descriptor.hasPackage || !descriptor.messageType.isEmpty else { continue }
                found.append(Found(descriptor: descriptor, bytes: blob, binary: url.lastPathComponent))
                break
            }
        }
        return found
    }

    /// Walks protobuf fields from `start` while they are valid `FileDescriptorProto` fields and
    /// returns the offset just past the last one, or nil if not even the first field is valid.
    static func walk(_ b: [UInt8], from start: Int) -> Int? {
        var p = start
        var last: Int?
        while p < b.count {
            guard let (tag, afterTag) = varint(b, p), tag > 0 else { break }
            let number = Int(tag >> 3), wireType = Int(tag & 7)
            guard fileDescriptorFields[number] == wireType else { break }
            switch wireType {
            case 0:
                guard let (_, next) = varint(b, afterTag) else { return last }
                p = next
            case 2:
                guard let (length, next) = varint(b, afterTag), next + Int(length) <= b.count else { return last }
                p = next + Int(length)
            default:
                return last
            }
            last = p
        }
        return last
    }

    static func varint(_ b: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var p = start
        while p < b.count, shift < 64 {
            let byte = b[p]
            result |= UInt64(byte & 0x7F) << shift
            p += 1
            if byte < 0x80 { return (result, p) }
            shift += 7
        }
        return nil
    }

    /// Every Mach-O in a `.app`: the main executable and each embedded framework's binary.
    static func binaries(inApp app: URL) -> [URL] {
        var out = [URL]()
        let fm = FileManager.default
        let macOS = app.appendingPathComponent("Contents/MacOS")
        for name in (try? fm.contentsOfDirectory(atPath: macOS.path)) ?? [] {
            out.append(macOS.appendingPathComponent(name))
        }
        let frameworks = app.appendingPathComponent("Contents/Frameworks")
        for name in ((try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? []).sorted() where name.hasSuffix(".framework") {
            let base = (name as NSString).deletingPathExtension
            for candidate in ["\(name)/\(base)", "\(name)/Versions/A/\(base)"] {
                let url = frameworks.appendingPathComponent(candidate)
                if fm.fileExists(atPath: url.path) { out.append(url.resolvingSymlinksInPath()); break }
            }
        }
        return out
    }

    /// Scans every binary and merges by file name. The same name in two binaries must be the same
    /// bytes; a disagreement is an error, never a silent pick.
    static func all(inApp app: URL) throws -> [Found] {
        var byName = [String: Found]()
        for binary in binaries(inApp: app) {
            for item in try scan(binary) {
                if let existing = byName[item.descriptor.name] {
                    guard existing.bytes == item.bytes else {
                        throw Failure.conflictingDescriptors(name: item.descriptor.name, first: existing.binary, second: item.binary)
                    }
                } else {
                    byName[item.descriptor.name] = item
                }
            }
        }
        return byName.values.sorted { $0.descriptor.name < $1.descriptor.name }
    }
}
