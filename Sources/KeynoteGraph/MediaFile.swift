import Foundation

/// A QuickTime / MPEG-4 file's duration and video size, read from its boxes (ISO/IEC 14496-12):
/// `moov/mvhd` for the duration, each `moov/trak` with a `vide` handler for the size. No decoding
/// and no AVFoundation, so the core stays portable.
public struct MediaFile: Equatable, Sendable {
    /// Seconds.
    public var duration: Double
    /// The first video track's size in points, nil for audio-only files.
    public var videoSize: (width: Double, height: Double)?

    public var hasVideo: Bool { videoSize != nil }

    public static func == (a: MediaFile, b: MediaFile) -> Bool {
        a.duration == b.duration && a.videoSize?.width == b.videoSize?.width && a.videoSize?.height == b.videoSize?.height
    }

    public init(duration: Double, videoSize: (width: Double, height: Double)?) {
        self.duration = duration
        self.videoSize = videoSize
    }

    /// Nil unless the file has a `moov` box with a readable `mvhd`.
    public init?(_ data: Data) {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int? { i + 3 < b.count ? Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) : nil }
        func u64(_ i: Int) -> Int? { guard let hi = u32(i), let lo = u32(i + 4) else { return nil }; return hi << 32 | lo }
        func type(_ i: Int) -> String { i + 7 < b.count ? String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self) : "" }
        /// The boxes directly inside [start, end): (type, payload start, end).
        func boxes(_ start: Int, _ end: Int) -> [(String, Int, Int)] {
            var out = [(String, Int, Int)](), i = start
            while i + 8 <= end, var size = u32(i) {
                var header = 8
                if size == 1 { guard let large = u64(i + 8) else { break }; size = large; header = 16 }
                if size == 0 { size = end - i }
                guard size >= header, i + size <= end else { break }
                out.append((type(i), i + header, i + size))
                i += size
            }
            return out
        }
        guard let moov = boxes(0, b.count).first(where: { $0.0 == "moov" }) else { return nil }
        let inner = boxes(moov.1, moov.2)
        guard let mvhd = inner.first(where: { $0.0 == "mvhd" }) else { return nil }
        let v1 = b[mvhd.1] == 1
        guard let timescale = u32(mvhd.1 + (v1 ? 20 : 12)), timescale > 0,
              let units = v1 ? u64(mvhd.1 + 24) : u32(mvhd.1 + 16) else { return nil }
        duration = Double(units) / Double(timescale)
        videoSize = nil
        for trak in inner where trak.0 == "trak" {
            let parts = boxes(trak.1, trak.2)
            guard let mdia = parts.first(where: { $0.0 == "mdia" }),
                  let hdlr = boxes(mdia.1, mdia.2).first(where: { $0.0 == "hdlr" }),
                  hdlr.1 + 12 <= b.count, String(decoding: b[(hdlr.1 + 8)..<(hdlr.1 + 12)], as: UTF8.self) == "vide",
                  let tkhd = parts.first(where: { $0.0 == "tkhd" }) else { continue }
            let at = tkhd.1 + (b[tkhd.1] == 1 ? 88 : 76)       // width, height: 16.16 fixed point
            guard let w = u32(at), let h = u32(at + 4), w > 0, h > 0 else { continue }
            videoSize = (Double(w) / 65_536, Double(h) / 65_536)
            break
        }
    }
}
