import Foundation
import Testing
@testable import IWASnappy

/// Deterministic generator so AT-02's fuzz corpus is reproducible across machines.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    /// Random bytes (incompressible), a repeated short phrase (highly compressible), or a mix.
    static func buffer(size: Int, kind: Int, rng: inout SplitMix64) -> [UInt8] {
        switch kind % 3 {
        case 0:
            return (0..<size).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        case 1:
            let phrase = [UInt8]("Keynote keeps its presentations in Snappy-chunked protobufs. ".utf8)
            return (0..<size).map { phrase[$0 % phrase.count] }
        default:
            var out = [UInt8]()
            out.reserveCapacity(size)
            while out.count < size {
                let runLength = Int(rng.next() % 64) + 1
                let byte = UInt8(truncatingIfNeeded: rng.next())
                for _ in 0..<min(runLength, size - out.count) {
                    out.append(byte)
                }
                if out.count < size, rng.next() % 4 == 0 {
                    out.append(UInt8(truncatingIfNeeded: rng.next()))
                }
            }
            return out
        }
    }
}

@Suite("Snappy")
struct SnappyTests {
    @Test("hand-assembled literal + 1-byte-offset copy decodes")
    func literalAndShortCopy() throws {
        // preamble 12; literal "abc"; copy length 9 offset 3.
        let encoded: [UInt8] = [0x0C, 0x08, 0x61, 0x62, 0x63, 0x15, 0x03]
        #expect(try Snappy.decompress(encoded) == [UInt8]("abcabcabcabc".utf8))
    }

    @Test("2-byte and 4-byte offset copies decode, including overlapping runs")
    func longOffsetCopies() throws {
        // preamble 10; literal "ab"; copy len 8 offset 2 via tag 2; → "ab" repeated 5 times.
        let two: [UInt8] = [0x0A, 0x04, 0x61, 0x62, UInt8((7 << 2) | 2), 0x02, 0x00]
        #expect(try Snappy.decompress(two) == [UInt8]("ababababab".utf8))
        let four: [UInt8] = [0x0A, 0x04, 0x61, 0x62, UInt8((7 << 2) | 3), 0x02, 0x00, 0x00, 0x00]
        #expect(try Snappy.decompress(four) == [UInt8]("ababababab".utf8))
    }

    @Test("literal length escapes (1, 2, 3 extra bytes) decode")
    func literalEscapes() throws {
        for size in [61, 100, 255, 256, 300, 65536, 70000] {
            var rng = SplitMix64(seed: UInt64(size))
            let input = Fixtures.buffer(size: size, kind: 0, rng: &rng)
            let encoded = Snappy.compress(input)
            #expect(try Snappy.decompress(encoded) == input, "size \(size)")
        }
    }

    @Test("malformed streams throw instead of trapping")
    func malformed() {
        #expect(throws: SnappyError.self) { try Snappy.decompress([]) }
        // preamble says 4 bytes, literal of 3 → length mismatch
        #expect(throws: SnappyError.lengthMismatch(declared: 4, actual: 3)) {
            try Snappy.decompress([0x04, 0x08, 0x61, 0x62, 0x63])
        }
        // copy before the start of output
        #expect(throws: SnappyError.self) { try Snappy.decompress([0x04, 0x15, 0x09]) }
        // truncated literal
        #expect(throws: SnappyError.self) { try Snappy.decompress([0x04, 0x0C, 0x61]) }
    }

    @Test("AT-02: encode→decode is identity on 10,000 random buffers")
    func fuzzRoundTrip() throws {
        var rng = SplitMix64(seed: 0xDEC_C0DE)
        for i in 0..<10_000 {
            let size = Int(rng.next() % 1024)
            let input = Fixtures.buffer(size: size, kind: i, rng: &rng)
            let encoded = Snappy.compress(input)
            let decoded = try Snappy.decompress(encoded)
            #expect(decoded == input, "iteration \(i) size \(size)")
        }
    }

    @Test("AT-02: identity across the 64 KiB block boundary and on multi-block inputs")
    func blockBoundaries() throws {
        var rng = SplitMix64(seed: 65_536)
        for (i, size) in [0, 1, 2, 3, 4, 5, 15, 16, 17, 65_535, 65_536, 65_537, 131_072, 131_073, 300_001].enumerated() {
            for kind in 0..<3 {
                let input = Fixtures.buffer(size: size, kind: kind, rng: &rng)
                let decoded = try Snappy.decompress(Snappy.compress(input))
                #expect(decoded == input, "case \(i) size \(size) kind \(kind)")
            }
        }
    }

    @Test("compressible input actually shrinks")
    func compresses() {
        var rng = SplitMix64(seed: 1)
        let input = Fixtures.buffer(size: 100_000, kind: 1, rng: &rng)
        #expect(Snappy.compress(input).count < input.count / 10)
    }
}

@Suite("IWA chunk framing")
struct IWAChunkingTests {
    @Test("frame→deframe is identity, one chunk and many")
    func framingIdentity() throws {
        var rng = SplitMix64(seed: 7)
        for size in [0, 1, 1000, 1 << 20, (1 << 20) + 1, 3 * (1 << 20) + 17] {
            let input = Data(Fixtures.buffer(size: size, kind: 2, rng: &rng))
            let framed = try IWAChunking.compress(input)
            #expect(try IWAChunking.decompress(framed) == input, "size \(size)")
            let expectedChunks = max(1, (size + (1 << 20) - 1) / (1 << 20))
            #expect(try IWAChunking.chunkBodies(framed).count == expectedChunks, "size \(size)")
        }
    }

    @Test("each chunk starts with 0x00 and a 24-bit little-endian length")
    func header() throws {
        let framed = [UInt8](try IWAChunking.compress(Data("hello".utf8)))
        #expect(framed[0] == 0)
        let length = Int(framed[1]) | (Int(framed[2]) << 8) | (Int(framed[3]) << 16)
        #expect(length == framed.count - 4)
    }

    @Test("a non-zero header byte is rejected")
    func badHeader() throws {
        var framed = [UInt8](try IWAChunking.compress(Data("hello".utf8)))
        framed[0] = 0x01
        #expect(throws: IWAChunkingError.invalidHeader(expected: 0, found: 1, at: 0)) {
            try IWAChunking.decompress(Data(framed))
        }
    }
}

@Suite("Varint")
struct VarintTests {
    @Test("write→read identity on boundary values")
    func identity() throws {
        for value: UInt64 in [0, 1, 127, 128, 255, 300, 16_383, 16_384, UInt64(UInt32.max), UInt64.max] {
            var out = [UInt8]()
            Varint.write(value, into: &out)
            #expect(out.count == Varint.encodedLength(value))
            let back = try Varint.read(out, at: 0)
            #expect(back.value == value)
            #expect(back.length == out.count)
        }
    }

    @Test("truncated varint throws")
    func truncated() {
        #expect(throws: VarintError.truncated(at: 0)) { try Varint.read([0x80], at: 0) }
    }
}
