import Foundation
import SwiftProtobuf
import Testing
@testable import IWASchema

@Suite("Schema 15.4")
struct SchemaTests {
    @Test("the pinned registry loads with the identities the bytes showed (docs/spec.md §4)")
    func registryIdentities() throws {
        let registry = try TypeRegistry.load(version: TypeRegistry.pinnedVersion)
        #expect(registry.keynoteVersion == "15.4")
        #expect(registry.types.count == 625)
        // Identifier 1 is type 1 in Document.iwa and identifier 2 is type 11006 in Metadata.iwa in
        // every corpus deck; the registry, read from Keynote's own registration calls, agrees.
        #expect(registry.name(for: 1) == "KN.DocumentArchive")
        #expect(registry.name(for: 11006) == "TSP.PackageMetadata")
        #expect(registry.name(for: 2001) == "TSWP.StorageArchive")
        #expect(registry.name(for: 5) == "KN.SlideArchive")
        // Declared deprecated by 15.4 and still present in decks last saved by Keynote 6.5.
        #expect(registry.name(for: 6219) == nil)
        #expect(registry.resolves(6219))
        #expect(!registry.resolves(999_999))
    }

    @Test("the shipped reference-strength table loads and classifies what the corpus showed")
    func referenceStrength() throws {
        let strength = try ReferenceStrength.load(version: TypeRegistry.pinnedVersion)
        #expect(strength.keynoteVersion == "15.4")
        // Learned from the 106 Corpus/templates decks Keynote 15.4 authored.
        #expect(strength.fields.count == 126)
        #expect(strength.strength(of: "KN.SlideNodeArchive.2") == .strong)     // the slide a node shows
        #expect(strength.strength(of: "KN.SlideArchive.42") == .strong)
        #expect(strength.strength(of: "TSD.DrawableArchive.2") == .weak)      // parent back-pointer
        #expect(strength.strength(of: "TSS.StyleArchive.5") == .weak)         // stylesheet back-pointer
        #expect(strength.strength(of: "TSWP.StorageArchive.2") == .weak)      // owner back-pointer
        #expect(strength.fields.values.filter { $0 == .mixed }.isEmpty)
    }

    @Test("every registry type dispatches to a generated message whose proto name matches")
    func dispatchMatchesRegistry() throws {
        let registry = try TypeRegistry.load(version: TypeRegistry.pinnedVersion)
        for (type, name) in registry.types {
            let messageType = try #require(Schema.messageType(for: type), "type \(type) (\(name)) has no dispatch")
            #expect(messageType.protoMessageName == name, "type \(type)")
        }
        #expect(Schema.messageType(for: 6219) == nil)
    }

    @Test("generated MessageInfo carries the field names the bytes confirmed (spec §4 rows 3, 3a)")
    func messageInfoFields() throws {
        var info = TSP_MessageInfo()
        info.type = 1
        info.version = [1, 0, 5]
        info.length = 68
        info.objectReferences = [2405, 2402]
        info.baseMessageIndex = 0
        info.diffMergeVersion = [65535, 65535, 4_294_967_295]
        let bytes: Data = try info.serializedData()
        // 1 type, 2 packed version, 3 length, 5 packed object_references, 7, 8 packed.
        #expect(Array(bytes.prefix(2)) == [0x08, 0x01])
        #expect(bytes.contains(0x2A))   // field 5, wire type 2
        #expect(bytes.contains(0x38))   // field 7, wire type 0
        #expect(bytes.contains(0x42))   // field 8, wire type 2
        #expect(try TSP_MessageInfo(serializedBytes: bytes) == info)
    }

    @Test("invariant 2 in generated code: an unknown field survives decode and encode")
    func unknownFieldsSurvive() throws {
        var reference = TSP_Reference()
        reference.identifier = 42
        var bytes: Data = try reference.serializedData()
        bytes.append(contentsOf: [0xF8, 0x3E, 0x07])   // field 999, varint 7: not in TSP.Reference
        let decoded = try TSP_Reference(serializedBytes: bytes)
        #expect(decoded.identifier == 42)
        #expect(try decoded.serializedData() == bytes)
    }
}
