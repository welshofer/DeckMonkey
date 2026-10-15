import Foundation
import IWASnappy
import SwiftProtobuf

/// `Corpus/hostile` (docs/spec.md §11, AT-26): one deliberately broken copy of a Keynote-authored
/// template per validator rule. Each case changes exactly one thing, directly on the component
/// streams, and is written without validation: that is the point. `expected` names the error the
/// file must raise (`KeynoteError` or `ValidationIssue.Kind` case name).
public enum HostileCorpus {
    public struct Case: Sendable {
        public let name: String
        public let expected: String
        public let package: IWAPackage
    }

    public enum Failure: Error, CustomStringConvertible {
        case templateLacks(String)

        public var description: String {
            switch self {
            case .templateLacks(let what): return "the template has no \(what) to break"
            }
        }
    }

    public static func cases(from template: KeynoteDocument) throws -> [Case] {
        let base = template.package
        var out = [Case]()

        // Duplicate identifier: a slide object appears a second time, in another component.
        do {
            var p = base
            let slide = try firstRecord(in: template) { $0.info.messageInfos.first?.type == 5 }
            try edit(&p, "Index/Document.iwa") { $0.append(slide.record) }
            out.append(Case(name: "duplicate-identifier", expected: "duplicateIdentifier", package: p))
        }

        // Dangling reference: the document's show points at an object that does not exist; the
        // header lists the new target, as invariant 4 requires.
        do {
            var p = base
            let missing = template.store.highestIdentifier + 1_000
            try edit(&p, template.store.entry(for: 1)!.component) { records in
                guard let i = records.firstIndex(where: { $0.identifier == 1 }) else { return }
                var document = try KN_DocumentArchive(serializedBytes: records[i].payloads[0], extensions: Schema.extensions, partial: true)
                let old = document.show.identifier
                document.show.identifier = missing
                let payload = try document.serializedData(partial: true)
                var info = records[i].info.messageInfos[0]
                info.setLength(UInt32(payload.count))
                info.setObjectReferences(info.objectReferences.map { $0 == old ? missing : $0 })
                records[i].info.messageInfos[0] = info
                records[i].payloads[0] = payload
            }
            out.append(Case(name: "dangling-reference", expected: "danglingObjectReference", package: p))
        }

        // Truncated chunk: Document.iwa cut in the middle of its first chunk.
        do {
            var p = base
            let iwa = base.data("Index/Document.iwa")!
            p.set("Index/Document.iwa", iwa.prefix(iwa.count / 2))
            out.append(Case(name: "truncated-chunk", expected: "componentUnreadable", package: p))
        }

        // Unknown type: a slide's message claims a type the pinned registry does not know.
        do {
            var p = base
            let slide = try firstRecord(in: template) { $0.info.messageInfos.first?.type == 5 }
            try edit(&p, slide.component) { records in
                guard let i = records.firstIndex(where: { $0.identifier == slide.record.identifier }) else { return }
                let fields = records[i].info.messageInfos[0].fields.map { field in
                    field.number == MessageInfo.typeField ? WireField(number: field.number, value: .varint(999_999)) : field
                }
                records[i].info.messageInfos[0] = try MessageInfo(fields: fields)
            }
            out.append(Case(name: "unknown-type", expected: "unknownType", package: p))
        }

        // Offset past text length: a paragraph-style entry moved beyond the end of its text.
        do {
            var p = base
            let storage = try firstRecord(in: template) { record in
                guard record.info.messageInfos.first?.type == 2001,
                      let s = try? TSWP_StorageArchive(serializedBytes: record.payloads[0], extensions: Schema.extensions, partial: true)
                else { return false }
                return !s.tableParaStyle.entries.isEmpty
            }
            try edit(&p, storage.component) { records in
                guard let i = records.firstIndex(where: { $0.identifier == storage.record.identifier }) else { return }
                var s = try TSWP_StorageArchive(serializedBytes: records[i].payloads[0], extensions: Schema.extensions, partial: true)
                let last = s.tableParaStyle.entries.count - 1
                s.tableParaStyle.entries[last].characterIndex = UInt32(TextOffsets.textLength(s) + 5)
                let payload = try s.serializedData(partial: true)
                records[i].info.messageInfos[0].setLength(UInt32(payload.count))
                records[i].payloads[0] = payload
            }
            out.append(Case(name: "offset-past-text-length", expected: "textOffset", package: p))
        }

        // External reference with an explicit object identifier 0: a spelling Keynote never writes
        // (a reference to a component's root object leaves the identifier out), and a cloned
        // slide's entry spelled that way made Keynote refuse the deck as damaged.
        do {
            var p = base
            try edit(&p, "Index/Metadata.iwa") { records in
                guard let i = records.firstIndex(where: { $0.identifier == 2 }) else { return }
                var metadata = try TSP_PackageMetadata(serializedBytes: records[i].payloads[0], extensions: Schema.extensions, partial: true)
                guard let c = metadata.components.firstIndex(where: { $0.externalReferences.contains { !$0.hasObjectIdentifier } }),
                      let e = metadata.components[c].externalReferences.firstIndex(where: { !$0.hasObjectIdentifier })
                else { throw Failure.templateLacks("root-object external reference") }
                metadata.components[c].externalReferences[e].objectIdentifier = 0
                let payload = try metadata.serializedData(partial: true)
                records[i].info.messageInfos[0].setLength(UInt32(payload.count))
                records[i].payloads[0] = payload
            }
            out.append(Case(name: "external-reference-zero", expected: "externalReference", package: p))
        }
        return out
    }

    static func firstRecord(in document: KeynoteDocument, where match: (ArchiveRecord) -> Bool) throws -> (component: String, record: ArchiveRecord) {
        for component in document.store.components {
            if let record = component.records.first(where: match) { return (component.name, record) }
        }
        throw Failure.templateLacks("matching object")
    }

    static func edit(_ package: inout IWAPackage, _ component: String, _ body: (inout [ArchiveRecord]) throws -> Void) throws {
        guard let compressed = package.data(component) else { throw Failure.templateLacks(component) }
        var records = try ArchiveStream.split(try IWAChunking.decompress(compressed))
        try body(&records)
        package.set(component, try IWAChunking.compress(ArchiveStream.join(records)))
    }
}
