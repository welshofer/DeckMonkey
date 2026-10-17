import Foundation
import IWAArchive
import IWASnappy
import IWAContainer
import IWASchema
import SwiftProtobuf

/// Parts: the Keynote-made drawables new objects are copied from (nothing is synthesized). A parts
/// package holds only what inserting needs: each part and what only it keeps alive (a text box's
/// storage and captions, a picture's captions), and the records those point at outside themselves
/// (styles with their parent chains, the stylesheet) so the copy can be re-pointed at the target
/// deck's own styles. No slides, masters, theme or data: a picture's pixels are always the
/// caller's.
extension KeynoteDocument {
    public enum PartsFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case noPart(String)
        public var description: String {
            switch self { case .noPart(let what): return "the parts package has no \(what)" }
        }
    }

    /// A parts package of `drawables` (text items, shapes, pictures directly on slides of this deck).
    public func partsPackage(drawables: [UInt64]) throws -> IWAPackage {
        let referrers = referrerIndex()
        var keep = Set<UInt64>()
        if let show = showIdentifier { keep.insert(show) }
        var wanted = Set<UInt64>()
        for d in drawables {
            guard let (archive, _) = drawableArchive(d), archive.hasParent else { throw PartsFailure.noPart("drawable \(d) on a slide") }
            wanted.formUnion(heldOnly(by: [d], referrers: referrers, keeping: keep.union([archive.parent.identifier])))
        }
        // What the parts point at outside themselves, and every style's parents: the resolver
        // matches them to the target's by identifier, name or role.
        var frontier = Array(wanted)
        var outside = Set<UInt64>()
        while let id = frontier.popLast() {
            guard let record = store.record(for: id) else { continue }
            for (i, info) in record.info.messageInfos.enumerated() where info.baseMessageIndex == nil && i < record.payloads.count {
                guard let derived = try? ReferenceDerivation.derive(type: info.type, payload: record.payloads[i]) else { continue }
                for ref in derived.objects where ref != 0 && !wanted.contains(ref) && !outside.contains(ref) && store.record(for: ref) != nil {
                    let type = store.record(for: ref)?.info.messageInfos.first?.type
                    guard type != Self.slideType else { continue }          // the parent slide: re-pointed on insert
                    outside.insert(ref)
                    if let r = store.record(for: ref), ForeignResolver.styleSuper(r) != nil { frontier.append(ref) }
                }
            }
        }
        var out = ObjectStore()
        let ids = wanted.union(outside).sorted()
        var records = ids.compactMap { store.record(for: $0) }.map { ArchiveRecord(info: $0.info, payloads: $0.payloads, isDirty: false) }
        // The deck's package metadata, trimmed to the parts' own UUID-map entries: an insert gives
        // each copy that had a UUID a fresh one (Keynote asserts on a slide object without).
        if let record = store.record(for: 2), var metadata = packageMetadata, var info = metadata.components.first {
            let entries = metadata.components.flatMap(\.objectUuidMapEntries).filter { wanted.contains($0.identifier) }
            info.locator = "Parts"; info.preferredLocator = "Parts"
            info.objectUuidMapEntries = entries
            info.dataReferences = []; info.externalReferences = []
            metadata.components = [info]
            metadata.datas = []
            var payloads = record.payloads
            payloads[0] = try metadata.serializedData(partial: true)
            var minfo = record.info
            minfo.messageInfos[0] = try Self.remapped(minfo.messageInfos[0], identifiers: [:], length: UInt32(payloads[0].count))
            records.append(ArchiveRecord(info: minfo, payloads: payloads, isDirty: false))
        }
        out.addComponent("Index/Parts.iwa", records: records)
        out.finalize()
        var entries = [String: Data]()
        for (name, decompressed) in out.joinedComponents() { entries[name] = try IWAChunking.compress(decompressed) }
        return IWAPackage(form: .zip, entries: entries)
    }

    /// The parts a package holds: its plain text box and its picture.
    public var parts: (textBox: UInt64?, image: UInt64?) {
        var text: UInt64?, image: UInt64?
        for id in store.identifiers.sorted() {
            switch store.record(for: id)?.info.messageInfos.first?.type {
            case Self.shapeInfoType?: if text == nil, decoded(TSWP_ShapeInfoArchive.self, id)?.isTextBox == true { text = id }
            case Self.imageType?: if image == nil { image = id }
            default: break
            }
        }
        return (text, image)
    }

    /// A new text box on `slide`, copied from `parts`' plain text box and restyled to this deck's
    /// default text box style: at `frame` (a width alone keeps the height automatic), holding
    /// `paragraphs`. Returns its identifier.
    @discardableResult
    public mutating func insertTextBox(onto slide: UInt64, frame: Frame, paragraphs: [TextParagraphs.Paragraph], parts: KeynoteDocument) throws -> UInt64 {
        guard let part = parts.parts.textBox else { throw PartsFailure.noPart("text box") }
        return try insertDrawable(part, from: parts, onto: slide, frame: frame, paragraphs: paragraphs)
    }

    /// A new picture on `slide` showing `bytes` (PNG, JPEG, GIF or TIFF), copied from `parts`'
    /// plain picture and restyled to this deck's default image style, fixed at `frame`.
    @discardableResult
    public mutating func insertImage(_ bytes: Data, preferredFileName: String, onto slide: UInt64, frame: Frame, parts: KeynoteDocument) throws -> UInt64 {
        guard let part = parts.parts.image else { throw PartsFailure.noPart("picture") }
        let new = try insertDrawable(part, from: parts, onto: slide, frame: frame)
        _ = try replaceImage(new, with: bytes, preferredFileName: preferredFileName)
        return new
    }
}
