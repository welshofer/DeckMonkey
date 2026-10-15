import Foundation

/// SHA-1 (FIPS 180-4), pure Swift so the portable core needs no CryptoKit. `TSP.DataInfo.digest` is
/// the SHA-1 of the file's bytes (verified on Keynote 15.4's own files).
public enum SHA1 {
    public static func digest(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<80 { w[i] = (w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]).rotatedLeft(1) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
                }
                let t = a.rotatedLeft(5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, b.rotatedLeft(30), a, t)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - $0 * 8)) } }
    }
}

extension UInt32 {
    fileprivate func rotatedLeft(_ n: UInt32) -> UInt32 { self << n | self >> (32 - n) }
}

/// An image file's format and pixel size, read from its header (no decoding, no CoreGraphics).
public struct ImageFile: Equatable, Sendable {
    public enum Format: String, Sendable { case png, jpeg, gif, tiff }

    public var format: Format
    public var width: Int
    public var height: Int

    /// The extension Keynote gives the stored file.
    public var fileExtension: String {
        switch format {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        case .tiff: return "tiff"
        }
    }

    public init(format: Format, width: Int, height: Int) {
        (self.format, self.width, self.height) = (format, width, height)
    }

    /// Nil for anything that is not a well-formed PNG, JPEG, GIF or TIFF header.
    public init?(_ data: Data) {
        let b = [UInt8](data.prefix(256 * 1024))
        func u16be(_ i: Int) -> Int? { i + 1 < b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : nil }
        func u32be(_ i: Int) -> Int? { i + 3 < b.count ? Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) : nil }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            guard let w = u32be(16), let h = u32be(20), w > 0, h > 0 else { return nil }
            (format, width, height) = (.png, w, h)
        } else if b.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            guard b.count >= 10 else { return nil }
            let w = Int(b[6]) | Int(b[7]) << 8, h = Int(b[8]) | Int(b[9]) << 8
            guard w > 0, h > 0 else { return nil }
            (format, width, height) = (.gif, w, h)
        } else if b.starts(with: [0xFF, 0xD8]) {
            // Walk the segments to the first start-of-frame marker (SOF0…SOF15 but DHT, JPG, DAC).
            var i = 2
            var found: (Int, Int)?
            while i + 3 < b.count, found == nil {
                guard b[i] == 0xFF else { return nil }
                let marker = b[i + 1]
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
                guard let length = u16be(i + 2), length >= 2 else { return nil }
                if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                    guard let h = u16be(i + 5), let w = u16be(i + 7) else { return nil }
                    found = (w, h)
                }
                i += 2 + length
            }
            guard let (w, h) = found, w > 0, h > 0 else { return nil }
            (format, width, height) = (.jpeg, w, h)
        } else if b.starts(with: [0x49, 0x49, 0x2A, 0x00]) || b.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            let little = b[0] == 0x49
            func u16(_ i: Int) -> Int? { i + 1 < b.count ? (little ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1])) : nil }
            func u32(_ i: Int) -> Int? {
                guard i + 3 < b.count else { return nil }
                return little ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
                    : Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            }
            guard let ifd = u32(4), let count = u16(ifd) else { return nil }
            var w: Int?, h: Int?
            for e in 0..<count {
                let at = ifd + 2 + e * 12
                guard let tag = u16(at), let type = u16(at + 2) else { break }
                let value = type == 3 ? u16(at + 8) : u32(at + 8)
                if tag == 256 { w = value }
                if tag == 257 { h = value }
            }
            guard let w, let h, w > 0, h > 0 else { return nil }
            (format, width, height) = (.tiff, w, h)
        } else {
            return nil
        }
    }
}
