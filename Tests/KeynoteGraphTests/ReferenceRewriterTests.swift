import Foundation
import IWASchema
import SwiftProtobuf
import Testing
@testable import KeynoteGraph

@Suite("Reference rewriter")
struct ReferenceRewriterTests {
    @Test("a rewritten reference re-decodes with the new identifier; unknown fields and other bytes survive")
    func synthetic() throws {
        let index = try FieldIndex.load(version: TypeRegistry.pinnedVersion)
        var node = KN_SlideNodeArchive()
        node.isSkipped = false
        node.hasBuilds_p = false
        node.hasTransition_p = false
        node.slide = TSP_Reference.with { $0.identifier = 300 }        // 2 varint bytes
        node.children = [TSP_Reference.with { $0.identifier = 5 }]
        node.thumbnails = [TSP_DataReference.with { $0.identifier = 300 }] // a data reference: untouched
        var bytes: Data = try node.serializedData(partial: true)
        bytes.append(contentsOf: [0xF8, 0x3E, 0x07])                    // field 999: unknown
        let rewriter = ReferenceRewriter(index: index, identifiers: [300: 1_000_000, 5: 6])
        let out = try rewriter.rewrite(bytes, message: "KN.SlideNodeArchive")
        let back = try KN_SlideNodeArchive(serializedBytes: out, partial: true)
        #expect(back.slide.identifier == 1_000_000 && back.children.map(\.identifier) == [6])
        #expect(back.thumbnails.map(\.identifier) == [300])
        #expect(Array(back.unknownFields.data) == [0xF8, 0x3E, 0x07])
        #expect(try ReferenceRewriter(index: index, identifiers: [:]).rewrite(bytes, message: "KN.SlideNodeArchive") == bytes)
    }

    /// Completeness against the decoder: every reference the Visitor derives, the rewriter moves.
    @Test("in every corpus payload, mapping each reference r → r+1 re-derives exactly the shifted list", .enabled(if: !CorpusTests.corpusFiles().isEmpty, "no corpus"))
    func corpusCompleteness() throws {
        let index = try FieldIndex.load(version: TypeRegistry.pinnedVersion)
        var payloads = 0, references = 0
        var failures = [String]()
        for url in CorpusTests.corpusFiles() {
            guard let document = try? KeynoteDocument.open(url) else { continue }
            for component in document.store.components {
                for record in component.records {
                    for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil {
                        guard let type = Schema.messageType(for: info.type),
                              let derived = try? ReferenceDerivation.derive(type: info.type, payload: record.payloads[i]) else { continue }
                        payloads += 1
                        let identity = try ReferenceRewriter(index: index, identifiers: Dictionary(derived.objects.map { ($0, $0) }, uniquingKeysWith: { a, _ in a }))
                            .rewrite(record.payloads[i], message: type.protoMessageName)
                        if identity != record.payloads[i], failures.count < 10 { failures.append("\(url.lastPathComponent) \(record.identifier): identity map changed bytes") }
                        guard !derived.objects.isEmpty else { continue }
                        references += derived.objects.count
                        let shift = Dictionary(derived.objects.map { ($0, $0 + 1) }, uniquingKeysWith: { a, _ in a })
                        let out = try ReferenceRewriter(index: index, identifiers: shift).rewrite(record.payloads[i], message: type.protoMessageName)
                        let again = try ReferenceDerivation.derive(type: info.type, payload: out)
                        if again.objects != derived.objects.map({ $0 + 1 }) || again.data != derived.data || again.hasUnknownFields != derived.hasUnknownFields {
                            if failures.count < 10 { failures.append("\(url.lastPathComponent) \(record.identifier) type \(info.type): \(derived.objects.prefix(4)) → \(again.objects.prefix(4))") }
                        }
                    }
                }
            }
        }
        print("rewriter: \(payloads) payloads, \(references) references shifted and re-derived, \(failures.count) failure(s)")
        failures.forEach { print("  \($0)") }
        #expect(failures.isEmpty)
    }
}

/// Hostile input: parsers of untrusted bytes refuse, never trap (house rule: fail loud, typed).
@Suite("Hostile input")
struct HostileInputTests {
    @Test("the rewriter refuses absurd lengths and deep nesting with typed errors")
    func rewriter() throws {
        let index = try FieldIndex.load(version: TypeRegistry.pinnedVersion)
        let rewriter = ReferenceRewriter(index: index, identifiers: [1: 2])
        // Field 2 of KN.SlideNodeArchive (a TSP.Reference) with a length near UInt64.max.
        let huge = Data([0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        #expect(throws: ReferenceRewriter.Failure.self) { try rewriter.rewrite(huge, message: "KN.SlideNodeArchive") }
        // A message type with a field of its own type, nested deeper than the limit.
        let recursive = index.messageFields.lazy.compactMap { entry -> (String, Int)? in
            entry.value.first(where: { $0.value == entry.key }).map { (entry.key, $0.key) }
        }.first
        #expect(recursive != nil, "the schema has a self-recursive message")
        if let (name, field) = recursive {
            var bytes = Data()
            for _ in 0..<(ReferenceRewriter.maximumDepth + 8) {
                var wrapped = Data([UInt8(field << 3 | 2)])
                var n = bytes.count
                while n >= 0x80 { wrapped.append(UInt8(n & 0x7F) | 0x80); n >>= 7 }
                wrapped.append(UInt8(n))
                bytes = wrapped + bytes
            }
            if field < 16 { #expect(throws: ReferenceRewriter.Failure.tooDeep) { try rewriter.rewrite(bytes, message: name) } }
        }
    }

    @Test("MediaFile refuses a 64-bit box size past Int, an empty mvhd, and truncation")
    func media() {
        // A box claiming size 1 (64-bit size follows) of 0xFFFF_FFFF_FFFF_FFFF.
        let huge = Data([0, 0, 0, 1] + Array("moov".utf8) + [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 32))
        #expect(MediaFile(huge) == nil)
        // moov holding an mvhd with no payload.
        let empty = Data([0, 0, 0, 16] + Array("moov".utf8) + [0, 0, 0, 8] + Array("mvhd".utf8))
        #expect(MediaFile(empty) == nil)
        #expect(MediaFile(Data([0, 0, 0])) == nil)
        #expect(ImageFile(Data([0x89, 0x50, 0x4E, 0x47])) == nil)
    }
}
