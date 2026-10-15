import Foundation
import IWASchema
import SwiftProtobuf
import Testing
@testable import KeynoteGraph

@Suite("Image replace")
struct ImageReplaceTests {
    @Test("SHA-1 matches FIPS 180-4 vectors")
    func sha1() {
        func hex(_ s: String) -> String { SHA1.digest(Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(hex("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(hex("abc") == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        #expect(hex(String(repeating: "a", count: 1_000)) == "291e9a6c66994949b57ba5e650361e98fc36b1ba")
    }

    static func png(_ w: UInt32, _ h: UInt32) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        for v in [w, h] { d.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        return d + Data([8, 2, 0, 0, 0])
    }

    @Test("image headers: PNG, GIF, JPEG, TIFF sizes; anything else is refused")
    func headers() {
        #expect(ImageFile(Self.png(320, 240)) == ImageFile(format: .png, width: 320, height: 240))
        #expect(ImageFile(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x40, 0x01, 0xF0, 0x00]))?.width == 320)
        // JPEG: SOI, an APP0 segment to skip, then SOF0 with height 600, width 800.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x02, 0x58, 0x03, 0x20, 0x03])
        #expect(ImageFile(jpeg) == ImageFile(format: .jpeg, width: 800, height: 600))
        // TIFF, little-endian: one IFD with ImageWidth 640 (short) and ImageLength 480 (long).
        var tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x02, 0x00])
        tiff += Data([0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x80, 0x02, 0x00, 0x00])
        tiff += Data([0x01, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0xE0, 0x01, 0x00, 0x00])
        #expect(ImageFile(tiff) == ImageFile(format: .tiff, width: 640, height: 480))
        #expect(ImageFile(Data("not an image".utf8)) == nil)
        #expect(ImageFile(Data([0xFF, 0xD8, 0xFF])) == nil)
    }

    /// AT-18 and AT-19 as a property over the corpus: replace every image that has a local file.
    @Test("AT-18/19: replacing every corpus image keeps data consistent: digest is SHA-1, no orphans", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus"))
    func corpusReplaceEveryImage() throws {
        let replacement = Self.stripes()
        let digest = Data(SHA1.digest(replacement))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var replaced = 0, refused = 0, decks = 0
        var failures = [String]()
        func fail(_ s: String) { if failures.count < 10 { failures.append(s) } }
        for url in CorpusTests.corpusFiles() {
            guard var document = try? KeynoteDocument.open(url), document.writtenByNewerKeynote == nil,
                  let metadata = document.packageMetadata else { continue }
            let local = Set(metadata.datas.filter { $0.storedFileName != nil }.map(\.identifier))
            var touched = [UInt64]()
            for id in document.images {
                guard let image = document.decoded(TSD_ImageArchive.self, id), image.hasData, local.contains(image.data.identifier) else { continue }
                do {
                    try document.replaceImage(id, with: replacement, preferredFileName: "stripes.png")
                    touched.append(id)
                    replaced += 1
                } catch is KeynoteDocument.ImageReplaceFailure {
                    refused += 1
                } catch {
                    fail("\(url.lastPathComponent) image \(id): \(error)")
                }
            }
            guard !touched.isEmpty else { continue }
            decks += 1
            let out = dir.appendingPathComponent("\(decks).key")
            do {
                try document.save(to: out)
                let reread = try KeynoteDocument.open(out)
                let errors = reread.validate().filter { $0.severity == .error }
                if !errors.isEmpty { fail("\(url.lastPathComponent): \(errors.prefix(3))") }
                let m = try #require(reread.packageMetadata)
                var referenced = Set<UInt64>()
                for c in reread.store.components { for r in c.records { for i in r.info.messageInfos { referenced.formUnion(i.dataReferences) } } }
                let unreferenced = m.datas.filter { !referenced.contains($0.identifier) }.map(\.identifier)
                if !unreferenced.isEmpty { fail("\(url.lastPathComponent): AT-19 unreferenced DataInfo \(unreferenced)") }
                let described = Set(m.datas.compactMap(\.storedFileName).map { "Data/" + $0 })
                let undescribed = reread.package.dataNames.filter { !described.contains($0) }
                if !undescribed.isEmpty { fail("\(url.lastPathComponent): AT-19 undescribed files \(undescribed.prefix(3))") }
                for id in touched {
                    let image = try #require(reread.decoded(TSD_ImageArchive.self, id))
                    let info = try #require(m.datas.first { $0.identifier == image.data.identifier })
                    if info.digest != digest { fail("\(url.lastPathComponent) image \(id): AT-18 digest is not SHA-1 of the file") }
                    if reread.package.data("Data/" + info.fileName) != replacement { fail("\(url.lastPathComponent) image \(id): file bytes differ") }
                    if image.naturalSize.width != 320 || image.naturalSize.height != 240 { fail("\(url.lastPathComponent) image \(id): naturalSize \(image.naturalSize)") }
                }
            } catch {
                fail("\(url.lastPathComponent): \(error)")
            }
            try? FileManager.default.removeItem(at: out)
        }
        print("image replace: \(replaced) images in \(decks) decks, \(refused) refused (Keynote-edited images), \(failures.count) failure(s)")
        failures.forEach { print("  \($0)") }
        #expect(failures.isEmpty)
        #expect(replaced > 0)
    }

    /// A 320×240 PNG of red and blue stripes, built in code.
    static func stripes() -> Data {
        let w = 320, h = 240
        var raw = [UInt8]()
        for _ in 0..<h {
            raw.append(0)
            for x in 0..<w { raw += (x / 20) % 2 == 0 ? [40, 40, 220] : [220, 40, 40] }
        }
        // Stored (uncompressed) deflate blocks keep this free of a zlib dependency.
        var deflate: [UInt8] = [0x78, 0x01]
        var i = 0
        while i < raw.count {
            let n = min(65_535, raw.count - i)
            deflate += [i + n == raw.count ? 1 : 0, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            deflate += raw[i..<(i + n)]
            i += n
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        let adler = b << 16 | a
        deflate += [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let t = [UInt8](type.utf8)
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in t + body {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            crc ^= 0xFFFF_FFFF
            func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            return be(UInt32(body.count)) + t + body + be(crc)
        }
        let ihdr: [UInt8] = [0, 0, 1, 0x40, 0, 0, 0, 0xF0, 8, 2, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr) + chunk("IDAT", deflate) + chunk("IEND", []))
    }
}

@Suite("Media replace")
struct MediaReplaceTests {
    /// A minimal MPEG-4: ftyp, then moov with mvhd (timescale 600, duration 1200 = 2 s) and, for
    /// video, a trak whose mdia/hdlr says "vide" and whose tkhd says 640×360.
    static func mp4(video: Bool, version1: Bool = false) -> Data {
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let n = body.count + 8
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + body
        }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let mvhd = version1
            ? box("mvhd", [1, 0, 0, 0] + [UInt8](repeating: 0, count: 16) + u32(600) + u32(0) + u32(1200) + [UInt8](repeating: 0, count: 80))
            : box("mvhd", [0, 0, 0, 0] + u32(0) + u32(0) + u32(600) + u32(1200) + [UInt8](repeating: 0, count: 80))
        var moov = mvhd
        if video {
            let tkhd = box("tkhd", [0, 0, 0, 3] + [UInt8](repeating: 0, count: 72) + u32(640 << 16) + u32(360 << 16))
            let hdlr = box("hdlr", [0, 0, 0, 0] + u32(0) + Array("vide".utf8) + [UInt8](repeating: 0, count: 13))
            moov += box("trak", tkhd + box("mdia", hdlr))
        }
        return Data(box("ftyp", Array("isom".utf8) + u32(0)) + box("moov", moov))
    }

    @Test("MPEG-4 boxes: duration from mvhd (v0 and v1), video size from the vide track's tkhd")
    func boxes() {
        #expect(MediaFile(Self.mp4(video: true)) == MediaFile(duration: 2, videoSize: (640, 360)))
        #expect(MediaFile(Self.mp4(video: false)) == MediaFile(duration: 2, videoSize: nil))
        #expect(MediaFile(Self.mp4(video: false, version1: true))?.duration == 2)
        #expect(MediaFile(Data("not a movie".utf8)) == nil)
    }

    /// The media feature deck: its movie and audio clip are replaced, the old media, poster and
    /// audio dropped with their files, and nothing orphaned (AT-18/19 for media).
    @Test("replacing the feature deck's movie and audio keeps data consistent", .enabled(if: FileManager.default.fileExists(atPath: CorpusTests.repoRoot.appendingPathComponent("Corpus/features/media.key").path), "no Corpus/features"))
    func featureDeck() throws {
        var document = try KeynoteDocument.open(CorpusTests.repoRoot.appendingPathComponent("Corpus/features/media.key"))
        let movie = try #require(document.movies.first { document.decoded(TSD_MovieArchive.self, $0).map { !$0.audioOnly && $0.hasMovieData } ?? false })
        let audio = try #require(document.movies.first { document.decoded(TSD_MovieArchive.self, $0)?.audioOnly ?? false })
        #expect(throws: KeynoteDocument.MediaReplaceFailure.posterRequired) {
            try document.replaceMedia(movie, with: Self.mp4(video: true), preferredFileName: "clip.mp4")
        }
        #expect(throws: KeynoteDocument.MediaReplaceFailure.kindMismatch(audio, wasAudio: true)) {
            try document.replaceMedia(audio, with: Self.mp4(video: true), preferredFileName: "clip.mp4")
        }
        let poster = ImageReplaceTests.stripes()
        let m = try document.replaceMedia(movie, with: Self.mp4(video: true), preferredFileName: "clip.mp4", poster: poster)
        let a = try document.replaceMedia(audio, with: Self.mp4(video: false), preferredFileName: "sound.m4a")
        #expect(m.fileName.hasPrefix("clip-") && m.posterFileName?.hasPrefix("posterImage-") == true && m.removedData.count == 2)
        #expect(a.fileName.hasPrefix("sound-") && a.removedData.count == 1)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("deckmonkey-media-\(UUID().uuidString).key")
        defer { try? FileManager.default.removeItem(at: out) }
        try document.save(to: out)
        let reread = try KeynoteDocument.open(out)
        #expect(reread.validate().filter { $0.severity == .error }.isEmpty)
        let replaced = try #require(reread.decoded(TSD_MovieArchive.self, movie))
        #expect(replaced.endTime == 2 && replaced.naturalSize.width == 640 && !replaced.hasFingerprint)
        let metadata = try #require(reread.packageMetadata)
        var referenced = Set<UInt64>()
        for c in reread.store.components { for r in c.records { for i in r.info.messageInfos { referenced.formUnion(i.dataReferences) } } }
        #expect(metadata.datas.allSatisfy { referenced.contains($0.identifier) })
        let described = Set(metadata.datas.compactMap(\.storedFileName).map { "Data/" + $0 })
        #expect(reread.package.dataNames.allSatisfy(described.contains))
        let info = try #require(metadata.datas.first { $0.identifier == replaced.movieData.identifier })
        #expect(info.digest == Data(SHA1.digest(Self.mp4(video: true))))
    }
}
