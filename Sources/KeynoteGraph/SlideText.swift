import Foundation
import IWASchema
import SwiftProtobuf

/// Where a slide's text lives: its placeholders' storages by role, its free text boxes' storages in
/// component order, and its presenter notes' storage. Phase 4 fills these from the Deck IR.
public struct SlideText: Equatable, Sendable {
    /// The master's name ("Title & Bullets"), nil when the slide has none.
    public var master: String?
    public var title: UInt64?
    public var body: UInt64?
    /// Storages of free text boxes (shapes with text, not placeholders), in component order.
    public var textBoxes: [UInt64] = []
    public var notes: UInt64?
    /// The placeholders' frames on the slide (points).
    public var titleFrame: KeynoteDocument.Frame?
    public var bodyFrame: KeynoteDocument.Frame?
}

extension KeynoteDocument {
    static let slideArchiveType: UInt32 = 5, noteType: UInt32 = 15

    /// The text targets of `slide` (a KN.SlideArchive identifier).
    public func slideText(_ slide: UInt64) -> SlideText? {
        guard let archive = decoded(KN_SlideArchive.self, slide), let component = store.entry(for: slide)?.component,
              let records = store.records(in: component) else { return nil }
        var text = SlideText()
        if archive.hasTemplateSlide, let master = decoded(KN_SlideArchive.self, archive.templateSlide.identifier), master.hasName {
            text.master = master.name
        }
        for record in records {
            guard let type = record.info.messageInfos.first?.type else { continue }
            if type == Self.placeholderArchiveType, let p = decoded(KN_PlaceholderArchive.self, record.identifier), p.super.hasOwnedStorage {
                let g = p.super.super.super.geometry
                let frame = Frame(x: Double(g.position.x), y: Double(g.position.y), width: Double(g.size.width), height: Double(g.size.height))
                switch p.kind {
                case .kKindTitlePlaceholder: text.title = p.super.ownedStorage.identifier; text.titleFrame = frame
                case .kKindBodyPlaceholder: text.body = p.super.ownedStorage.identifier; text.bodyFrame = frame
                default: break
                }
            } else if type == Self.shapeInfoType, let shape = decoded(TSWP_ShapeInfoArchive.self, record.identifier), shape.hasOwnedStorage {
                text.textBoxes.append(shape.ownedStorage.identifier)
            } else if type == Self.noteType, let note = decoded(KN_NoteArchive.self, record.identifier), note.hasContainedStorage {
                text.notes = note.containedStorage.identifier
            }
        }
        return text
    }

    /// The drawables `slide` owns, in order.
    public func slideDrawables(_ slide: UInt64) -> [UInt64] {
        decoded(KN_SlideArchive.self, slide)?.ownedDrawables.map(\.identifier) ?? []
    }

    /// The master each slide uses, in show order.
    public func slideMasters() throws -> [String?] {
        try slideList().map { slideText($0.slide)?.master }
    }

    static let placeholderArchiveType: UInt32 = 7
}
