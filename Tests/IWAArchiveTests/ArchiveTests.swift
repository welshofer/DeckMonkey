import Foundation
import Testing
import IWASnappy
@testable import IWAArchive

/// Builds synthetic archive records the way Keynote lays them out, for tests that have no
/// real corpus file at hand.
enum Synth {
    static func messageInfo(type: UInt32, version: [UInt32] = [2, 0, 0], length: UInt32, refs: [UInt64] = [], data: [UInt64] = []) -> MessageInfo {
        var info = MessageInfo(type: type, version: version, length: length)
        info.setObjectReferences(refs)
        info.setDataReferences(data)
        return info
    }

    static func record(id: UInt64, type: UInt32, payload: [UInt8], refs: [UInt64] = [], data: [UInt64] = []) -> ArchiveRecord {
        let info = messageInfo(type: type, length: UInt32(payload.count), refs: refs, data: data)
        return ArchiveRecord(info: ArchiveInfo(identifier: id, messageInfos: [info]), payloads: [Data(payload)])
    }

    static func stream(_ records: [ArchiveRecord]) -> Data {
        ArchiveStream.join(records)
    }
}

@Suite("Wire format")
struct WireTests {
    @Test("fields of every supported wire type survive decode→encode")
    func allWireTypes() throws {
        let fields: [WireField] = [
            WireField(number: 1, value: .varint(300)),
            WireField(number: 2, value: .fixed64(0x0102_0304_0506_0708)),
            WireField(number: 3, value: .lengthDelimited(Data("hello".utf8))),
            WireField(number: 4, value: .fixed32(0xDEAD_BEEF)),
            WireField(number: 1_000, value: .varint(UInt64.max)),
        ]
        let bytes = Wire.encode(fields)
        #expect(try Wire.fields(bytes) == fields)
        #expect(Wire.encode(try Wire.fields(bytes)) == bytes)
    }

    @Test("packed and unpacked repeated varints both read")
    func repeated() throws {
        #expect(try Wire.repeatedVarints(Wire.packed([1, 300, 70_000])) == [1, 300, 70_000])
        #expect(try Wire.repeatedVarints(.varint(42)) == [42])
    }

    @Test("groups are refused, not trapped")
    func groups() {
        #expect(throws: WireError.unsupportedWireType(3, at: 0)) { try Wire.fields([0x0B]) }
    }
}

@Suite("ArchiveInfo")
struct ArchiveInfoTests {
    @Test("a synthesized header decodes to the same typed values")
    func synthesize() throws {
        let info = Synth.messageInfo(type: 10_000, version: [2, 1, 0], length: 42, refs: [7, 8], data: [99])
        let header = ArchiveInfo(identifier: 12_345, messageInfos: [info])
        let decoded = try ArchiveInfo(bytes: header.encoded())
        #expect(decoded.identifier == 12_345)
        #expect(decoded.shouldMerge == false)
        #expect(decoded.messageInfos.count == 1)
        #expect(decoded.messageInfos[0].type == 10_000)
        #expect(decoded.messageInfos[0].version == [2, 1, 0])
        #expect(decoded.messageInfos[0].length == 42)
        #expect(decoded.messageInfos[0].objectReferences == [7, 8])
        #expect(decoded.messageInfos[0].dataReferences == [99])
        #expect(decoded.encoded() == header.encoded())
    }

    @Test("invariant 2: an unknown field in the header survives decode→encode")
    func unknownFieldPreserved() throws {
        var fields = [WireField]()
        fields.append(WireField(number: 1, value: .varint(5)))
        fields.append(WireField(number: 2, value: .lengthDelimited(Data(Synth.messageInfo(type: 1, length: 0).encoded()))))
        fields.append(WireField(number: 3, value: .varint(1)))                      // should_merge
        fields.append(WireField(number: 77, value: .lengthDelimited(Data("future".utf8))))
        let bytes = Wire.encode(fields)
        let decoded = try ArchiveInfo(bytes: bytes)
        #expect(decoded.shouldMerge == true)
        #expect(decoded.encoded() == bytes)
        // Unknown fields inside a MessageInfo survive too.
        var infoFields = Synth.messageInfo(type: 1, length: 0).fields
        infoFields.append(WireField(number: 55, value: .fixed32(9)))
        let info = try MessageInfo(fields: infoFields)
        #expect(info.encoded() == Wire.encode(infoFields))
    }

    @Test("mutating a MessageInfo rewrites only that field")
    func mutation() throws {
        var info = Synth.messageInfo(type: 3, length: 10, refs: [1, 2, 3])
        info.setLength(20)
        info.setObjectReferences([9])
        let decoded = try MessageInfo(fields: try Wire.fields(info.encoded()))
        #expect(decoded.length == 20)
        #expect(decoded.objectReferences == [9])
        #expect(decoded.type == 3)
        #expect(decoded.version == [2, 0, 0])
    }

    @Test("a header without an identifier is an error")
    func missingIdentifier() {
        #expect(throws: ArchiveInfoError.missingIdentifier) { try ArchiveInfo(bytes: [0x18, 0x01]) }
    }
}

@Suite("Archive stream")
struct ArchiveStreamTests {
    @Test("AT-04: split→join is identity, and records come back typed")
    func splitJoin() throws {
        let records = [
            Synth.record(id: 1, type: 1, payload: [UInt8](repeating: 0xAB, count: 1_000), refs: [2, 3]),
            Synth.record(id: 2, type: 10_000, payload: [], refs: []),
            Synth.record(id: 3, type: 10_001, payload: [1, 2, 3], data: [900]),
        ]
        let stream = Synth.stream(records)
        let split = try ArchiveStream.split(stream)
        #expect(split == records)
        #expect(ArchiveStream.join(split) == stream)
        #expect(split[0].info.messageInfos[0].objectReferences == [2, 3])
        #expect(split[2].info.messageInfos[0].dataReferences == [900])
    }

    @Test("a record whose payload runs past the end is reported with its offset")
    func truncated() {
        var stream = [UInt8](Synth.stream([Synth.record(id: 1, type: 1, payload: [1, 2, 3, 4])]))
        stream.removeLast(2)
        #expect(throws: ArchiveStreamError.self) { try ArchiveStream.split(Data(stream)) }
    }
}

@Suite("Object store")
struct ObjectStoreTests {
    @Test("two-pass load: merges attach to their base, duplicates are reported")
    func mergesAndDuplicates() throws {
        var store = ObjectStore()
        try store.load(component: "Index/Document.iwa", decompressed: Synth.stream([
            Synth.record(id: 1, type: 1, payload: [0]),
            Synth.record(id: 2, type: 2, payload: [0], refs: [1]),
        ]))
        var merge = Synth.record(id: 2, type: 2, payload: [1])
        merge.info = try ArchiveInfo(bytes: Wire.encode(merge.info.fields + [WireField(number: ArchiveInfo.shouldMergeField, value: .varint(1))]))
        try store.load(component: "Index/Merge.iwa", decompressed: Synth.stream([
            merge,
            Synth.record(id: 1, type: 1, payload: [9]),   // duplicate base
            Synth.record(id: 3, type: 3, payload: [0], refs: [404]),
        ]))
        store.finalize()
        #expect(store.objectCount == 3)
        #expect(store.entry(for: 2)?.merges.count == 1)
        #expect(store.entry(for: 2)?.merges.first?.component == "Index/Merge.iwa")
        #expect(store.issues.contains(.duplicateIdentifier(1, components: ["Index/Document.iwa", "Index/Merge.iwa"])))
        #expect(store.highestIdentifier == 3)
        #expect(store.danglingObjectReferences.map(\.to) == [404])
        #expect(store.typeHistogram == [1: 1, 2: 1, 3: 1])
        let joined = store.joinedComponents()
        #expect(joined.count == 2)
        #expect(joined[0].name == "Index/Document.iwa")
    }

    @Test("a merge with no base is reported")
    func mergeWithoutBase() throws {
        var store = ObjectStore()
        var merge = Synth.record(id: 5, type: 1, payload: [])
        merge.info = try ArchiveInfo(bytes: Wire.encode(merge.info.fields + [WireField(number: ArchiveInfo.shouldMergeField, value: .varint(1))]))
        try store.load(component: "Index/X.iwa", decompressed: Synth.stream([merge]))
        store.finalize()
        #expect(store.objectCount == 0)
        #expect(store.issues == [.mergeWithoutBase(5, component: "Index/X.iwa")])
    }
}
