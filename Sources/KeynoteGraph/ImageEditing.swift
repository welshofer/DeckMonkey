import Foundation
import IWASchema
import SwiftProtobuf

/// Phase 2: replace an image's pixels (docs/spec.md §9), the way Keynote 15.4 writes an inserted
/// image: a `TSP.DataInfo` whose digest is the SHA-1 of the file, stored as
/// `Data/<stem>-<id>.<ext>` with its original name as `preferred_file_name`, image attributes
/// carrying the pixel size, and `materialized_length`; the `TSD.ImageArchive` points at it, with
/// `naturalSize`, `originalSize` and its traced outline set to the new pixel size. The shape's frame
/// is kept: the new image fills the old frame.
///
/// Keynote's thumbnail (`thumbnailData`, a "-small" copy it generates) is dropped rather than left
/// showing the old pixels; Keynote makes a new one when it needs it. Any `DataInfo` the image no
/// longer refers to and nothing else does is removed with its file and its data-metadata entry, so
/// no orphan is written (AT-19; 0 of 5,996 DataInfos in Keynote's own files are unreferenced).
///
/// Refused rather than guessed: images Keynote has edited (adjustments, enhancement, instant alpha,
/// a kept original), and files that are not PNG, JPEG, GIF or TIFF.
extension KeynoteDocument {
    public enum ImageReplaceFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case notAnImage(UInt64)
        case unsupportedFile
        case editedImage(UInt64, String)
        case noPackageMetadata

        public var description: String {
            switch self {
            case .notAnImage(let id): return "object \(id) is not a TSD.ImageArchive"
            case .unsupportedFile: return "the new file is not a PNG, JPEG, GIF or TIFF"
            case .editedImage(let id, let what): return "image \(id) carries Keynote edits (\(what)); Phase 2 replaces unedited images only"
            case .noPackageMetadata: return "the document has no decodable PackageMetadata"
            }
        }
    }

    public struct ImageReplaceReport: Equatable, Sendable {
        public var image: UInt64
        public var newData: UInt64
        public var fileName: String
        public var removedData: [UInt64] = []
        public var removedFiles: [String] = []
    }

    static let imageType: UInt32 = 3005

    /// Every image object, in component order.
    public var images: [UInt64] {
        store.components.flatMap { $0.records }.filter { $0.info.messageInfos.first?.type == Self.imageType }.map(\.identifier)
    }

    @discardableResult
    public mutating func replaceImage(_ image: UInt64, with bytes: Data, preferredFileName: String) throws -> ImageReplaceReport {
        guard let record = store.record(for: image), record.info.messageInfos.first?.type == Self.imageType,
              var archive = decoded(TSD_ImageArchive.self, image) else { throw ImageReplaceFailure.notAnImage(image) }
        let edits: [(Bool, String)] = [
            (archive.hasAdjustedImageData, "adjusted image"), (archive.hasEnhancedImageData, "enhanced image"),
            (archive.hasThumbnailAdjustedImageData, "adjusted thumbnail"), (archive.hasInstantAlphaPath, "instant alpha"),
            (archive.hasOriginalData, "kept original"), (archive.hasOriginalSvgdata, "SVG original"),
        ]
        if let edit = edits.first(where: \.0) { throw ImageReplaceFailure.editedImage(image, edit.1) }
        guard let file = ImageFile(bytes) else { throw ImageReplaceFailure.unsupportedFile }
        guard var metadata = packageMetadata else { throw ImageReplaceFailure.noPackageMetadata }

        // The new DataInfo, shaped like the ones Keynote writes.
        let stem = Self.fileStem(preferredFileName, fallback: "image")
        let previous = archive.hasData ? metadata.datas.first(where: { $0.identifier == archive.data.identifier }) : nil
        var info = Self.newDataInfo(bytes, stem: stem, extension: file.fileExtension, in: metadata)
        var attributes = previous?.attributes.TSD_ImageDataAttributes_imageDataAttributes ?? TSD_ImageDataAttributes()
        attributes.pixelSize = TSP_Size.with { $0.width = Float(file.width); $0.height = Float(file.height) }
        if !attributes.hasShouldBeInterpretedAsGenericIfUntagged { attributes.shouldBeInterpretedAsGenericIfUntagged = false }
        if !attributes.hasMayNeedWatermark { attributes.mayNeedWatermark = false }
        attributes.isDerivedFromOriginalAsset = false
        attributes.clearMediaLibraryAssetID()
        info.attributes = TSP_DataAttributes()
        info.attributes.TSD_ImageDataAttributes_imageDataAttributes = attributes

        // The image points at it, at its own size.
        let size = TSP_Size.with { $0.width = Float(file.width); $0.height = Float(file.height) }
        let oldData = [archive.hasData ? archive.data.identifier : nil, archive.hasThumbnailData ? archive.thumbnailData.identifier : nil].compactMap { $0 }
        archive.data = TSP_DataReference.with { $0.identifier = info.identifier }
        archive.clearThumbnailData()
        archive.naturalSize = size
        archive.originalSize = size
        if archive.hasTracedPath { archive.tracedPath = Self.rectanglePath(width: Float(file.width), height: Float(file.height)) }
        try replacePayload(of: image, with: try archive.serializedData(partial: true))

        let removed = try commitData([(info, bytes)], replacing: oldData, metadata: &metadata)
        return ImageReplaceReport(image: image, newData: info.identifier, fileName: info.fileName,
                                  removedData: removed.data, removedFiles: removed.files)
    }

    // MARK: Shared by image and media replace

    /// A file name stem from a caller's file name: no directories, no extension, never empty.
    static func fileStem(_ preferredFileName: String, fallback: String) -> String {
        let stem = ((preferredFileName as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? fallback : stem
    }

    /// A DataInfo as Keynote writes one: the next free data identifier, SHA-1 digest,
    /// `<stem>-<id>.<ext>`, the original name as preferred_file_name, materialized_length.
    static func newDataInfo(_ bytes: Data, stem: String, extension ext: String, in metadata: TSP_PackageMetadata, after: UInt64 = 0) -> TSP_DataInfo {
        let id = max(metadata.datas.map(\.identifier).max() ?? 0, after) + 1
        var info = TSP_DataInfo()
        info.identifier = id
        info.digest = Data(SHA1.digest(bytes))
        info.preferredFileName = "\(stem).\(ext)"
        info.fileName = "\(stem)-\(id).\(ext)"
        info.materializedLength = UInt64(bytes.count)
        return info
    }

    /// Adds the new data (DataInfo + file), drops the data in `old` that nothing refers to any more
    /// (DataInfo, file, data-metadata entry), and writes PackageMetadata back.
    mutating func commitData(_ new: [(TSP_DataInfo, Data)], replacing old: [UInt64], metadata: inout TSP_PackageMetadata) throws -> (data: [UInt64], files: [String]) {
        var referenced = Set<UInt64>()
        for component in store.components {
            for r in component.records { for m in r.info.messageInfos { referenced.formUnion(m.dataReferences) } }
        }
        var removedData = [UInt64](), removedFiles = [String]()
        for id in Set(old) where !referenced.contains(id) {
            guard let i = metadata.datas.firstIndex(where: { $0.identifier == id }) else { continue }
            let gone = metadata.datas.remove(at: i)
            removedData.append(id)
            if let name = gone.storedFileName, package.data("Data/" + name) != nil {
                package.remove("Data/" + name)
                removedFiles.append(name)
            }
        }
        for (info, bytes) in new {
            metadata.datas.append(info)
            package.set("Data/" + info.fileName, bytes)
        }
        try replacePayload(of: 2, with: try metadata.serializedData(partial: true))
        try removeDataMetadata(for: Set(removedData), map: metadata.hasDataMetadataMap ? metadata.dataMetadataMap.identifier : nil)
        return (removedData.sorted(), removedFiles.sorted())
    }

    /// Drops the data-metadata entries of removed data (the map's per-data fallback colours).
    mutating func removeDataMetadata(for removed: Set<UInt64>, map: UInt64?) throws {
        guard !removed.isEmpty, let map, var entries = decoded(TSP_DataMetadataMap.self, map) else { return }
        let before = entries.dataMetadataEntries.count
        entries.dataMetadataEntries.removeAll { removed.contains($0.dataIdentifier) }
        if entries.dataMetadataEntries.count != before {
            try replacePayload(of: map, with: try entries.serializedData(partial: true))
        }
    }

    /// The outline Keynote traces for an untouched image: its pixel rectangle.
    static func rectanglePath(width: Float, height: Float) -> TSP_Path {
        func element(_ type: TSP_Path.ElementType, _ x: Float? = nil, _ y: Float? = nil) -> TSP_Path.Element {
            var e = TSP_Path.Element()
            e.type = type
            if let x, let y { e.points = [TSP_Point.with { $0.x = x; $0.y = y }] }
            return e
        }
        var path = TSP_Path()
        path.elements = [element(.moveTo, 0, 0), element(.lineTo, width, 0), element(.lineTo, width, height),
                         element(.lineTo, 0, height), element(.closeSubpath), element(.moveTo, 0, 0)]
        return path
    }
}

extension TSP_DataInfo {
    /// The file this data is stored as in `Data/`, or nil for an app resource Keynote resolves from
    /// its own bundle: those carry no file name, or an empty one.
    public var storedFileName: String? { hasFileName && !fileName.isEmpty ? fileName : nil }
}
