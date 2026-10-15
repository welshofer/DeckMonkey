import Foundation
import Rostrum

/// Errors from reading or writing an iWork package container.
public enum IWAPackageError: Error, Equatable, Sendable {
    case notFound(String)
    /// The URL is neither a zip nor a package directory with `Index/` entries.
    case notAnIWorkPackage(String)
    /// `index.apxl` / `index.apxl.gz`: the pre-2013 XML format, out of scope (docs/spec.md §2).
    case unsupportedLegacyFormat(String)
    case zipEntryUnreadable(String)
    /// An entry name that could escape the package: absolute, empty components, `.` or `..`, a
    /// backslash or a NUL. Refused on open and on write, so no name read from a hostile file (or
    /// derived from one) ever becomes a path outside the package.
    case unsafeEntryName(String)
}

/// The physical container of a `.key` (or `.pages` / `.numbers`): a zip, or a package directory
/// with the same layout. Entries are kept as bytes; nothing is interpreted here except the
/// `Metadata/` plists, which are exposed read-only and carried through unchanged (invariant 5).
///
/// Layout:
///   Index/*.iwa           archive components; package directories (and some older zips) carry
///                         them inside an `Index.zip` instead, which is flattened on read and
///                         rebuilt on write
///   Data/*                media referenced by `TSP.DataReference`
///   Metadata/Properties.plist, BuildVersionHistory.plist, DocumentIdentifier
///   preview*.jpg          QuickLook previews
public struct IWAPackage: Sendable {
    public enum Form: Sendable, Equatable {
        case zip
        case directory
    }

    public let form: Form
    /// Whether the `Index/` components were read out of a nested `Index.zip`; written back the same way.
    public let nestedIndex: Bool
    public private(set) var entries: [String: Data]

    public init(form: Form, entries: [String: Data], nestedIndex: Bool = false) {
        self.form = form
        self.entries = entries
        self.nestedIndex = nestedIndex
    }

    // MARK: Open

    public static func open(_ url: URL) throws -> IWAPackage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw IWAPackageError.notFound(url.path)
        }
        if isDirectory.boolValue {
            return try openDirectory(url)
        }
        return try openZip(Data(contentsOf: url), name: url.lastPathComponent)
    }

    public static func openZip(_ data: Data, name: String = "<memory>") throws -> IWAPackage {
        let reader = try ZipReader(data: data)
        var entries = [String: Data]()
        for entryName in reader.entryNames where !entryName.hasSuffix("/") {
            do {
                entries[entryName] = try reader.data(forEntry: entryName)
            } catch {
                throw IWAPackageError.zipEntryUnreadable(entryName)
            }
        }
        let nestedIndex = try flattenNestedIndex(&entries)
        try validate(entries, name: name)
        return IWAPackage(form: .zip, entries: entries, nestedIndex: nestedIndex)
    }

    /// Expands an `Index.zip` entry into `Index/*` entries. Returns whether one was present.
    private static func flattenNestedIndex(_ entries: inout [String: Data]) throws -> Bool {
        guard let indexZip = entries["Index.zip"] else { return false }
        let inner = try ZipReader(data: indexZip)
        for innerName in inner.entryNames where !innerName.hasSuffix("/") {
            let flat = innerName.hasPrefix("Index/") ? innerName : "Index/" + innerName
            do {
                entries[flat] = try inner.data(forEntry: innerName)
            } catch {
                throw IWAPackageError.zipEntryUnreadable("Index.zip/" + innerName)
            }
        }
        entries["Index.zip"] = nil
        return true
    }

    private static func openDirectory(_ url: URL) throws -> IWAPackage {
        let fm = FileManager.default
        guard let subpaths = fm.subpaths(atPath: url.path) else {
            throw IWAPackageError.notAnIWorkPackage(url.path)
        }
        var entries = [String: Data]()
        for sub in subpaths {
            let fileURL = url.appendingPathComponent(sub)
            // A symbolic link would read a file from outside the package into its copy.
            if (try? fm.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw IWAPackageError.unsafeEntryName(sub)
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            entries[sub] = try Data(contentsOf: fileURL)
        }
        let nestedIndex = try flattenNestedIndex(&entries)
        try validate(entries, name: url.lastPathComponent)
        return IWAPackage(form: .directory, entries: entries, nestedIndex: nestedIndex)
    }

    /// True when `name` is a relative path of ordinary components: never absolute, no empty,
    /// `.` or `..` component, no backslash, no NUL. Checked on the UTF-8 bytes, as the file
    /// system and zip tools split them: a `/` followed by a combining mark is one Swift
    /// Character, and splitting Characters would hide the `..` after it.
    public static func isSafeEntryName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.first != 0x2F, !bytes.contains(0x5C), !bytes.contains(0) else { return false }
        return bytes.split(separator: 0x2F, omittingEmptySubsequences: false).allSatisfy { c in
            !c.isEmpty && !c.elementsEqual([0x2E]) && !c.elementsEqual([0x2E, 0x2E])
        }
    }

    private static func validate(_ entries: [String: Data], name: String) throws {
        if let unsafe = entries.keys.sorted().first(where: { !isSafeEntryName($0) }) {
            throw IWAPackageError.unsafeEntryName(unsafe)
        }
        if entries.keys.contains(where: { $0.lowercased().hasPrefix("index.apxl") }) {
            throw IWAPackageError.unsupportedLegacyFormat(name)
        }
        guard entries.keys.contains(where: { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }) else {
            throw IWAPackageError.notAnIWorkPackage(name)
        }
    }

    // MARK: Access

    public var entryNames: [String] { entries.keys.sorted() }

    /// `Index/*.iwa` entries in sorted order.
    public var iwaNames: [String] {
        entries.keys.filter { $0.hasPrefix("Index/") && $0.hasSuffix(".iwa") }.sorted()
    }

    public var dataNames: [String] {
        entries.keys.filter { $0.hasPrefix("Data/") }.sorted()
    }

    public func data(_ name: String) -> Data? { entries[name] }

    public mutating func set(_ name: String, _ data: Data) { entries[name] = data }

    public mutating func remove(_ name: String) { entries[name] = nil }

    // MARK: Metadata

    /// `Metadata/BuildVersionHistory.plist`: the Keynote builds that have saved this file, oldest first.
    public var buildVersionHistory: [String] {
        guard let data = entries["Metadata/BuildVersionHistory.plist"],
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let array = plist as? [Any] else { return [] }
        return array.compactMap { $0 as? String }
    }

    /// The string-valued keys of `Metadata/Properties.plist` (fileFormatVersion, documentUUID, …).
    public var properties: [String: String] {
        guard let data = entries["Metadata/Properties.plist"],
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        var out = [String: String]()
        for (key, value) in dict {
            if let s = value as? String {
                out[key] = s
            } else if let n = value as? NSNumber {
                out[key] = n.stringValue
            }
        }
        return out
    }

    public var fileFormatVersion: String? { properties["fileFormatVersion"] }

    public var documentIdentifier: String? {
        guard let data = entries["Metadata/DocumentIdentifier"] else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Write

    /// Writes the package. `form` defaults to the form it was read in.
    public func write(to url: URL, as form: Form? = nil) throws {
        if let unsafe = entryNames.first(where: { !Self.isSafeEntryName($0) }) {
            throw IWAPackageError.unsafeEntryName(unsafe)
        }
        switch form ?? self.form {
        case .zip:
            try zipData().write(to: url, options: .atomic)
        case .directory:
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            for name in entryNames where !(nestedIndex && name.hasPrefix("Index/")) {
                let fileURL = url.appendingPathComponent(name)
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try entries[name]!.write(to: fileURL)
            }
            if nestedIndex {
                try indexZipData().write(to: url.appendingPathComponent("Index.zip"))
            }
        }
    }

    /// The `Index.zip` a nested-index package carries: every `Index/*` entry, stored uncompressed.
    private func indexZipData() throws -> Data {
        var inner = ZipWriter()
        for name in iwaNames {
            inner.addFile(name: name, data: entries[name]!, compress: false)
        }
        return try inner.finalize()
    }

    /// The zip form as bytes, deterministic: entries sorted by name, fixed timestamps (Rostrum's writer).
    public func zipData() throws -> Data {
        if let unsafe = entryNames.first(where: { !Self.isSafeEntryName($0) }) {
            throw IWAPackageError.unsafeEntryName(unsafe)
        }
        var writer = ZipWriter()
        if nestedIndex {
            writer.addFile(name: "Index.zip", data: try indexZipData(), compress: false)
            for name in entryNames where !name.hasPrefix("Index/") {
                writer.addFile(name: name, data: entries[name]!, compress: shouldDeflate(name))
            }
        } else {
            for name in entryNames {
                writer.addFile(name: name, data: entries[name]!, compress: shouldDeflate(name))
            }
        }
        return try writer.finalize()
    }

    /// `.iwa` is already Snappy-compressed and media is already compressed; only text-like
    /// entries gain anything from DEFLATE.
    private func shouldDeflate(_ name: String) -> Bool {
        if name.hasSuffix(".iwa") { return false }
        if name.hasPrefix("Data/") { return false }
        if name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") || name.hasSuffix(".png") { return false }
        return true
    }
}

extension IWAPackageError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path): return "no such file: \(path)"
        case .notAnIWorkPackage(let path): return "\(path) is neither a zip nor a package directory with Index/ entries"
        case .unsupportedLegacyFormat(let path):
            return "\(path) is a Keynote '09 (APXL) document, which DeckMonkey does not read; open and save it in a current Keynote first"
        case .zipEntryUnreadable(let name): return "zip entry \(name) could not be read"
        case .unsafeEntryName(let name): return "entry name \"\(name)\" could escape the package; refused"
        }
    }
}
