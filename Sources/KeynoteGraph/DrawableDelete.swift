import Foundation
import IWASchema
import SwiftProtobuf

/// Deleting a drawable from a slide, as Keynote's Delete does: the drawable leaves the slide's
/// lists, and it goes with everything only it kept alive (its text storage, captions, mask, a
/// group's members), their UUID-map and data-index entries, and data nothing else uses. Placeholders
/// are hidden through the slide's style in Keynote, not deleted, and tables and charts carry
/// calculation-engine registrations: both are refused, as is an object a connection line attaches to.
extension KeynoteDocument {
    public enum DrawableDeleteFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case notDeletable(UInt64, String)
        case referencedFromOutside(UInt64, by: UInt64)

        public var description: String {
            switch self {
            case let .notDeletable(id, why): return "object \(id) cannot be deleted here: \(why)"
            case let .referencedFromOutside(id, by): return "object \(id) is still used by \(by) (a connection line or another slide)"
            }
        }
    }

    public struct DrawableDeleteReport: Equatable, Sendable {
        public var removedObjects: Int
        public var removedData: [UInt64]
    }

    @discardableResult
    public mutating func deleteDrawable(_ id: UInt64) throws -> DrawableDeleteReport {
        guard let type = store.record(for: id)?.info.messageInfos.first?.type else { throw DrawableDeleteFailure.notDeletable(id, "no such object") }
        let deletable: Set<UInt32> = [Self.shapeInfoType, Self.tsdShapeType, Self.imageType, Self.movieType, Self.groupType, Self.connectionLineType]
        guard deletable.contains(type) else {
            throw DrawableDeleteFailure.notDeletable(id, type == Self.placeholderType ? "a placeholder (Keynote hides placeholders)" : "type \(type)")
        }
        let drawable: TSD_DrawableArchive?
        switch type {
        case Self.shapeInfoType: drawable = decoded(TSWP_ShapeInfoArchive.self, id)?.super.super
        case Self.tsdShapeType: drawable = decoded(TSD_ShapeArchive.self, id)?.super
        case Self.imageType: drawable = decoded(TSD_ImageArchive.self, id)?.super
        case Self.movieType: drawable = decoded(TSD_MovieArchive.self, id)?.super
        case Self.groupType: drawable = decoded(TSD_GroupArchive.self, id)?.super
        default: drawable = decoded(TSD_ConnectionLineArchive.self, id)?.super.super
        }
        guard let d = drawable, d.hasParent, store.record(for: d.parent.identifier)?.info.messageInfos.first?.type == Self.slideType,
              var slide = decoded(KN_SlideArchive.self, d.parent.identifier), let showID = showIdentifier, var metadata = packageMetadata else {
            throw DrawableDeleteFailure.notDeletable(id, "not directly on a slide")
        }
        let slideID = d.parent.identifier
        let referrers = referrerIndex()
        let gone = heldOnly(by: [id], referrers: referrers, keeping: [slideID, showID])

        // Only the slide may hold what goes: anything else (a connection line's ends, another
        // slide) is refused rather than left dangling.
        for target in gone {
            for from in referrers[target] ?? [] where from != slideID && !gone.contains(from) {
                throw DrawableDeleteFailure.referencedFromOutside(id, by: from)
            }
        }
        // A connection line names what it connects by reference or UUID: refuse those too.
        for other in slide.ownedDrawables.map(\.identifier) where other != id && store.record(for: other)?.info.messageInfos.first?.type == Self.connectionLineType {
            if let line = decoded(TSD_ConnectionLineArchive.self, other),
               (line.hasConnectedFrom && line.connectedFrom.identifier == id) || (line.hasConnectedTo && line.connectedTo.identifier == id) {
                throw DrawableDeleteFailure.referencedFromOutside(id, by: other)
            }
        }

        slide.ownedDrawables.removeAll { $0.identifier == id }
        slide.drawablesZOrder.removeAll { $0.identifier == id }
        slide.sageTagToInfoMap.removeAll { $0.info.identifier == id }
        try replacePayload(of: slideID, with: try slide.serializedData(partial: true))

        var candidates = [UInt64]()
        for component in store.components {
            for record in component.records where gone.contains(record.identifier) {
                for info in record.info.messageInfos { candidates += info.dataReferences }
            }
        }
        store.removeRecords(gone)
        for c in metadata.components.indices {
            metadata.components[c].externalReferences.removeAll { $0.hasObjectIdentifier && gone.contains($0.objectIdentifier) }
            metadata.components[c].objectUuidMapEntries.removeAll { gone.contains($0.identifier) }
            for r in metadata.components[c].dataReferences.indices {
                metadata.components[c].dataReferences[r].objectReferenceList.removeAll { gone.contains($0.objectIdentifier) }
            }
            metadata.components[c].dataReferences.removeAll { $0.objectReferenceList.isEmpty }
        }
        let removed = try commitData([], replacing: candidates, metadata: &metadata)
        return DrawableDeleteReport(removedObjects: gone.count, removedData: removed.data)
    }

    static let groupType: UInt32 = 3008
    static let connectionLineType: UInt32 = 3009
}
