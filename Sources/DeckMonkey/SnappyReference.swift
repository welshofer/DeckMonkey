import Foundation
import IWAContainer
import IWASnappy

/// AT-01: our Snappy decode of every chunk in a corpus matches a reference decoder's.
///
/// The reference (cramjam, i.e. the Rust `snap` port of Google Snappy — the library Keynote
/// links) runs once, in `Scripts/snappy-crosscheck.py hash`, and leaves a manifest of SHA-256
/// hashes: per component, the hash of the compressed `.iwa`, of each chunk's decode, and of the
/// whole decoded stream. `check` re-derives every hash with `IWASnappy` and reports each
/// difference. With `emitTo`, it also writes our own re-compression of every component next to
/// its expected hash, so `snappy-crosscheck.py verify-ours` can prove the reference decoder
/// accepts what we write — the direction that matters for Keynote opening our files.
public enum SnappyReference {
    public static let manifestFormat = "deckmonkey-snappy-reference/1"

    public struct Manifest: Codable, Sendable, Equatable {
        public var format: String
        public var reference: String
        public var decks: [Deck]
    }

    public struct Deck: Codable, Sendable, Equatable {
        /// Relative to the manifest's directory, or absolute.
        public var path: String
        /// Set when the reference tool did not hash this deck (e.g. "legacy" for Keynote '09).
        public var skipped: String?
        public var components: [Component]?
    }

    public struct Component: Codable, Sendable, Equatable {
        public var name: String
        public var chunks: Int
        public var compressedSHA256: String
        public var decompressedSHA256: String
        public var chunkSHA256: [String]

        enum CodingKeys: String, CodingKey {
            case name
            case chunks
            case compressedSHA256 = "compressed_sha256"
            case decompressedSHA256 = "decompressed_sha256"
            case chunkSHA256 = "chunk_sha256"
        }
    }

    public struct Mismatch: Sendable, Equatable, CustomStringConvertible {
        public let deck: String
        public let component: String?
        public let detail: String

        public var description: String {
            "\(deck)" + (component.map { " \($0)" } ?? "") + ": \(detail)"
        }
    }

    public struct Report: Sendable, Equatable {
        public var decksChecked = 0
        public var decksSkipped = 0
        public var componentsChecked = 0
        public var chunksChecked = 0
        public var mismatches: [Mismatch] = []

        public var isClean: Bool { mismatches.isEmpty }

        public var summaryLine: String {
            let verdict = isClean ? "MATCH" : "MISMATCH (\(mismatches.count))"
            return "snappy-check \(verdict): \(chunksChecked) chunks in \(componentsChecked) components of \(decksChecked) deck(s)"
                + (decksSkipped > 0 ? ", \(decksSkipped) skipped by the reference" : "")
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case unsupportedFormat(String)
    }

    /// One component re-compressed by us, for the reference decoder to verify.
    struct EmittedItem: Codable {
        var file: String
        var decompressedSHA256: String

        enum CodingKeys: String, CodingKey {
            case file
            case decompressedSHA256 = "decompressed_sha256"
        }
    }

    struct EmittedManifest: Codable {
        var format = "deckmonkey-snappy-ours/1"
        var items: [EmittedItem]
    }

    public static func load(_ url: URL) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.format == manifestFormat else { throw Error.unsupportedFormat(manifest.format) }
        return manifest
    }

    public static func check(manifestAt url: URL, emitTo emitDirectory: URL? = nil) throws -> Report {
        let manifest = try load(url)
        return try check(manifest, relativeTo: url.deletingLastPathComponent(), emitTo: emitDirectory)
    }

    public static func check(_ manifest: Manifest, relativeTo base: URL, emitTo emitDirectory: URL? = nil) throws -> Report {
        var report = Report()
        var emitted = [EmittedItem]()
        if let emitDirectory {
            try FileManager.default.createDirectory(at: emitDirectory, withIntermediateDirectories: true)
        }
        for (deckIndex, deck) in manifest.decks.enumerated() {
            if deck.skipped != nil {
                report.decksSkipped += 1
                continue
            }
            let components = deck.components ?? []
            let deckURL = deck.path.hasPrefix("/") ? URL(fileURLWithPath: deck.path) : base.appendingPathComponent(deck.path)
            let package: IWAPackage
            do {
                package = try IWAPackage.open(deckURL)
            } catch {
                report.mismatches.append(Mismatch(deck: deck.path, component: nil, detail: "could not open: \(error)"))
                continue
            }
            report.decksChecked += 1
            let expectedNames = Set(components.map(\.name))
            for extra in package.iwaNames where !expectedNames.contains(extra) {
                report.mismatches.append(Mismatch(deck: deck.path, component: extra, detail: "component not in the reference manifest"))
            }
            for component in components {
                func mismatch(_ detail: String) {
                    report.mismatches.append(Mismatch(deck: deck.path, component: component.name, detail: detail))
                }
                guard let iwa = package.data(component.name) else {
                    mismatch("component missing from the package")
                    continue
                }
                report.componentsChecked += 1
                let compressedHash = SHA256.hex(iwa)
                if compressedHash != component.compressedSHA256 {
                    mismatch("compressed bytes differ from what the reference hashed (\(compressedHash) vs \(component.compressedSHA256)); re-run the reference")
                    continue
                }
                let bodies: [Data]
                do {
                    bodies = try IWAChunking.chunkBodies(iwa)
                } catch {
                    mismatch("chunk framing: \(error)")
                    continue
                }
                if bodies.count != component.chunks {
                    mismatch("\(bodies.count) chunks, reference saw \(component.chunks)")
                }
                var whole = SHA256.Hasher()
                var decoded = [UInt8]()
                for (i, body) in bodies.enumerated() {
                    let plain: [UInt8]
                    do {
                        plain = try Snappy.decompress([UInt8](body))
                    } catch {
                        mismatch("chunk \(i): our decoder failed: \(error)")
                        continue
                    }
                    report.chunksChecked += 1
                    whole.update(plain)
                    decoded.append(contentsOf: plain)
                    let hash = SHA256.hex(plain)
                    if i < component.chunkSHA256.count, hash != component.chunkSHA256[i] {
                        mismatch("chunk \(i): our decode hashes \(hash), reference \(component.chunkSHA256[i])")
                    }
                }
                let wholeHash = SHA256.hexString(whole.finalize())
                if wholeHash != component.decompressedSHA256 {
                    mismatch("decoded stream hashes \(wholeHash), reference \(component.decompressedSHA256)")
                }
                if let emitDirectory {
                    let fileName = "\(deckIndex)-" + component.name.replacingOccurrences(of: "/", with: "_")
                    let recompressed = try IWAChunking.compress(Data(decoded))
                    try recompressed.write(to: emitDirectory.appendingPathComponent(fileName))
                    emitted.append(EmittedItem(file: fileName, decompressedSHA256: component.decompressedSHA256))
                }
            }
        }
        if let emitDirectory {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(EmittedManifest(items: emitted)).write(to: emitDirectory.appendingPathComponent("manifest.json"))
        }
        return report
    }
}
