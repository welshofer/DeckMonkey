import Foundation
import Rostrum

/// The fonts a renderer measures text with, found by the PostScript name Keynote stores
/// ("HelveticaNeue-Light"). Rostrum's `FontLibrary` keys faces by family and bold/italic only, so
/// a family's light, medium and regular faces would collide there; this index keeps every face.
///
/// Font files are indexed by reading only their `name` tables; a face's metrics are parsed
/// (Rostrum's `FontMetrics`) the first time a slide needs it.
public final class RenderFonts: @unchecked Sendable {
    public struct Face: Sendable, Equatable {
        public var postScriptName: String
        public var family: String
        public var style: String
        public var bold: Bool
        public var italic: Bool
        /// No `OS/2` table (Courier, AppleGothic): a classic Mac font, which Keynote sets with
        /// extra leading its `hhea` metrics do not carry.
        public var classic = false
    }

    private struct Source { var url: URL?; var data: Data?; var index: Int; var face: Face }

    private let lock = NSLock()
    private var sources: [String: Source] = [:]
    private var families: [String: [Face]] = [:]
    private var loaded: [String: FontMetrics] = [:]
    private var failed = Set<String>()

    public init() {}

    /// Indexes every `.ttf`, `.otf`, `.ttc` and `.otc` under `directories` (recursively).
    public static func library(directories: [URL]) -> RenderFonts {
        let fonts = RenderFonts()
        for directory in directories {
            guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            var files = [URL]()
            for case let file as URL in walker where ["ttf", "otf", "ttc", "otc"].contains(file.pathExtension.lowercased()) {
                files.append(file)
            }
            for file in files.sorted(by: { $0.path < $1.path }) { fonts.index(file: file) }
        }
        return fonts
    }

    /// The directories a Mac keeps its fonts in, system and user.
    public static var macOSFontDirectories: [URL] {
        var dirs = ["/System/Library/Fonts", "/Library/Fonts", NSHomeDirectory() + "/Library/Fonts"].map { URL(fileURLWithPath: $0) }
        let assets = URL(fileURLWithPath: "/System/Library/AssetsV2")
        if let entries = try? FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil) {
            dirs += entries.filter { $0.lastPathComponent.hasPrefix("com_apple_MobileAsset_Font") }.sorted { $0.path < $1.path }
        }
        return dirs
    }

    /// Indexes one font file; a file that does not parse is skipped.
    public func index(file: URL) {
        // Mapped, not read: indexing a Mac's fonts touches a few kilobytes of each file instead of
        // holding gigabytes of font data in memory.
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return }
        for (i, face) in SFNTNames.faces(in: data).enumerated() { add(Source(url: file, data: nil, index: i, face: face)) }
    }

    /// Registers font bytes (a face or a collection) a host already holds.
    public func register(_ data: Data) {
        for (i, face) in SFNTNames.faces(in: data).enumerated() { add(Source(url: nil, data: data, index: i, face: face)) }
    }

    private func add(_ source: Source) {
        lock.lock(); defer { lock.unlock() }
        let name = source.face.postScriptName
        guard sources[name] == nil else { return }
        sources[name] = source
        families[source.face.family.lowercased(), default: []].append(source.face)
    }

    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return sources.isEmpty }

    public func face(postScriptName name: String) -> Face? {
        lock.lock(); defer { lock.unlock() }
        return sources[name]?.face
    }

    /// The face of `name`'s family with the requested traits, preferring the closest style name.
    public func face(family: String, bold: Bool, italic: Bool, like name: String? = nil) -> Face? {
        lock.lock(); defer { lock.unlock() }
        let candidates = (families[family.lowercased()] ?? []).filter { $0.bold == bold && $0.italic == italic }
        let plain = candidates.first { ["regular", "roman", "book", "medium", "bold", "italic", "bold italic", "bolditalic", "oblique", "bold oblique"].contains($0.style.lowercased()) }
        return plain ?? candidates.sorted { $0.postScriptName < $1.postScriptName }.first
    }

    /// The face's font file on its own, for a page to embed: a face in a collection (`.ttc`) is
    /// copied out into a single-face file with its tables; nil when the face is unknown.
    public func faceData(postScriptName name: String) -> Data? {
        lock.lock()
        let source = sources[name]
        lock.unlock()
        guard let source, let data = source.data ?? source.url.flatMap({ try? Data(contentsOf: $0, options: .mappedIfSafe) }) else { return nil }
        return SFNTNames.singleFace(data, index: source.index)
    }

    public func metrics(postScriptName name: String) -> FontMetrics? {
        lock.lock()
        if let m = loaded[name] { lock.unlock(); return m }
        guard !failed.contains(name), let source = sources[name] else { lock.unlock(); return nil }
        lock.unlock()
        let data = source.data ?? source.url.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        let metrics = data.flatMap { try? FontMetrics(data: $0, fontIndex: source.index) }
        lock.lock(); defer { lock.unlock() }
        if let metrics { loaded[name] = metrics } else { failed.insert(name) }
        return metrics
    }
}

extension SFNTNames {
    /// Face `index` of `data` as a single-face font: a lone face is returned as is; a collection's
    /// face gets its own table directory, its tables copied after it on 4-byte boundaries.
    static func singleFace(_ data: Data, index: Int) -> Data? {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : nil }
        func u32(_ o: Int) -> Int? { o >= 0 && o + 4 <= b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : nil }
        guard b.count >= 12 else { return nil }
        guard b[0...3] == [0x74, 0x74, 0x63, 0x66] else { return index == 0 ? data : nil }  // 'ttcf'
        guard let count = u32(8), index < count, let start = u32(12 + 4 * index), let tables = u16(start + 4), tables < 512 else { return nil }
        var records = [(tag: [UInt8], checksum: [UInt8], offset: Int, length: Int)]()
        for t in 0..<tables {
            let r = start + 12 + 16 * t
            guard let offset = u32(r + 8), let length = u32(r + 12), offset + length <= b.count else { return nil }
            records.append((Array(b[r..<(r + 4)]), Array(b[(r + 4)..<(r + 8)]), offset, length))
        }
        var out = Array(b[start..<(start + 12)])   // sfnt version and the search fields, unchanged
        var position = 12 + 16 * tables
        var body = [UInt8]()
        for record in records {
            out += record.tag + record.checksum
            out += withUnsafeBytes(of: UInt32(position).bigEndian, Array.init) + withUnsafeBytes(of: UInt32(record.length).bigEndian, Array.init)
            body += b[record.offset..<(record.offset + record.length)]
            let pad = (4 - record.length % 4) % 4
            body += [UInt8](repeating: 0, count: pad)
            position += record.length + pad
        }
        return Data(out + body)
    }
}

/// Reads the PostScript name, family and style of every face in a font file from its `name` and
/// `OS/2` tables, without parsing anything else.
enum SFNTNames {
    static func faces(in data: Data) -> [RenderFonts.Face] {
        data.withUnsafeBytes { faces(in: $0.bindMemory(to: UInt8.self)) }
    }

    static func faces(in bytes: UnsafeBufferPointer<UInt8>) -> [RenderFonts.Face] {
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= bytes.count ? Int(bytes[o]) << 8 | Int(bytes[o + 1]) : nil }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3])
        }
        var offsets = [Int]()
        if u32(0) == 0x7474_6366 {  // 'ttcf'
            guard let count = u32(8), count < 1024 else { return [] }
            offsets = (0..<count).compactMap { u32(12 + 4 * $0) }
        } else {
            offsets = [0]
        }
        return offsets.compactMap { face(at: $0, bytes: bytes, u16: u16, u32: u32) }
    }

    private static func face(at start: Int, bytes: UnsafeBufferPointer<UInt8>, u16: (Int) -> Int?, u32: (Int) -> Int?) -> RenderFonts.Face? {
        guard let tables = u16(start + 4), tables < 512 else { return nil }
        var name: Int?, os2: Int?
        for t in 0..<tables {
            let r = start + 12 + 16 * t
            guard let tag = u32(r), let offset = u32(r + 8) else { return nil }
            if tag == 0x6E61_6D65 { name = offset }  // 'name'
            if tag == 0x4F53_2F32 { os2 = offset }  // 'OS/2'
        }
        guard let name, let count = u16(name + 2), let storage = u16(name + 4) else { return nil }
        var found = [Int: String]()
        var priority = [Int: Int]()
        for i in 0..<min(count, 2048) {
            let r = name + 6 + 12 * i
            guard let platform = u16(r), let encoding = u16(r + 2), let language = u16(r + 4), let id = u16(r + 6),
                  let length = u16(r + 8), let offset = u16(r + 10), [1, 2, 4, 6, 16, 17].contains(id) else { continue }
            let s = name + storage + offset
            guard s >= 0, s + length <= bytes.count else { continue }
            let raw = Array(bytes[s..<(s + length)])
            let text: String?
            let rank: Int
            if platform == 3 || platform == 0 {
                var units = [UInt16]()
                for j in stride(from: 0, to: raw.count - 1, by: 2) { units.append(UInt16(raw[j]) << 8 | UInt16(raw[j + 1])) }
                text = String(decoding: units, as: UTF16.self)
                rank = platform == 3 && (language == 0x409 || encoding == 0) ? 3 : 2
            } else if platform == 1, encoding == 0 {
                text = String(bytes: raw, encoding: .macOSRoman)
                rank = language == 0 ? 1 : 0
            } else { continue }
            guard let text, !text.isEmpty, rank > (priority[id] ?? -1) else { continue }
            found[id] = text
            priority[id] = rank
        }
        guard let ps = found[6], let family = found[16] ?? found[1] else { return nil }
        let style = found[17] ?? found[2] ?? "Regular"
        var bold = style.lowercased().contains("bold"), italic = style.lowercased().contains("italic") || style.lowercased().contains("oblique")
        if let os2, let selection = u16(os2 + 62) {
            bold = selection & 0x20 != 0
            italic = selection & 0x01 != 0 || selection & 0x200 != 0
        }
        return RenderFonts.Face(postScriptName: ps, family: family, style: style, bold: bold, italic: italic, classic: os2 == nil)
    }
}
