import Foundation
import IWASchema
import SwiftProtobuf

/// Phase 2: replace a movie's or an audio clip's media (docs/spec.md §9) through the same path as
/// images. In iWork an audio clip is a `TSD.MovieArchive` with `audioOnly`. Keynote 15.4 writes the
/// media as `Data/<stem>-<id>.<ext>` (a DataInfo with SHA-1 digest and materialized_length, no
/// attributes), `endTime` = the duration, `naturalSize`/`originalSize` = the video size, and for
/// video a poster frame `Data/posterImage-<id>.png`, all of which this mirrors. A poster cannot be
/// rendered without decoding video, so a video replacement takes the caller's poster image. The
/// movie's fingerprint (per-track sample digests of the old media) is dropped rather than left
/// describing other bytes. The frame is kept.
///
/// Refused rather than guessed: switching between audio and video, a video without a poster,
/// streaming or remote media, live-video placeholders, and files that are not MPEG-4/QuickTime.
extension KeynoteDocument {
    public enum MediaReplaceFailure: Error, Equatable, Sendable, CustomStringConvertible {
        case notAMovie(UInt64)
        case unsupportedFile
        case kindMismatch(UInt64, wasAudio: Bool)
        case posterRequired
        case unsupportedPoster
        case notReplaceable(UInt64, String)
        case noPackageMetadata

        public var description: String {
            switch self {
            case .notAMovie(let id): return "object \(id) is not a TSD.MovieArchive (movie or audio clip)"
            case .unsupportedFile: return "the new file is not an MPEG-4 or QuickTime file with a readable duration"
            case .kindMismatch(let id, let wasAudio): return "object \(id) is \(wasAudio ? "audio" : "a movie"); the new file is \(wasAudio ? "a movie" : "audio only")"
            case .posterRequired: return "a movie replacement needs a poster image (the frame shown when it is not playing)"
            case .unsupportedPoster: return "the poster is not a PNG, JPEG, GIF or TIFF"
            case .notReplaceable(let id, let why): return "object \(id) cannot be replaced: \(why)"
            case .noPackageMetadata: return "the document has no decodable PackageMetadata"
            }
        }
    }

    public struct MediaReplaceReport: Equatable, Sendable {
        public var object: UInt64
        public var fileName: String
        public var posterFileName: String?
        public var duration: Double
        public var removedData: [UInt64] = []
        public var removedFiles: [String] = []
    }

    static let movieType: UInt32 = 3007

    /// Every movie and audio clip, in component order.
    public var movies: [UInt64] {
        store.components.flatMap { $0.records }.filter { $0.info.messageInfos.first?.type == Self.movieType }.map(\.identifier)
    }

    @discardableResult
    public mutating func replaceMedia(_ object: UInt64, with bytes: Data, preferredFileName: String, poster: Data? = nil) throws -> MediaReplaceReport {
        guard store.record(for: object)?.info.messageInfos.first?.type == Self.movieType,
              var movie = decoded(TSD_MovieArchive.self, object) else { throw MediaReplaceFailure.notAMovie(object) }
        if movie.isLiveVideo { throw MediaReplaceFailure.notReplaceable(object, "a live-video placeholder") }
        if movie.streaming || movie.hasMovieRemoteURL { throw MediaReplaceFailure.notReplaceable(object, "streaming or remote media") }
        if movie.hasImportedAuxiliaryMovieData { throw MediaReplaceFailure.notReplaceable(object, "it carries an imported auxiliary movie") }
        guard let media = MediaFile(bytes) else { throw MediaReplaceFailure.unsupportedFile }
        if media.hasVideo == movie.audioOnly { throw MediaReplaceFailure.kindMismatch(object, wasAudio: movie.audioOnly) }
        var posterFile: ImageFile?
        if media.hasVideo {
            guard let poster else { throw MediaReplaceFailure.posterRequired }
            guard let p = ImageFile(poster) else { throw MediaReplaceFailure.unsupportedPoster }
            posterFile = p
        }
        guard var metadata = packageMetadata else { throw MediaReplaceFailure.noPackageMetadata }

        let ext = { () -> String in
            let e = (preferredFileName as NSString).pathExtension.lowercased()
            return e.isEmpty ? (media.hasVideo ? "mov" : "m4a") : e
        }()
        let info = Self.newDataInfo(bytes, stem: Self.fileStem(preferredFileName, fallback: media.hasVideo ? "movie" : "audio"), extension: ext, in: metadata)
        var new = [(info, bytes)]
        let old = [movie.hasMovieData ? movie.movieData.identifier : nil, movie.hasPosterImageData ? movie.posterImageData.identifier : nil].compactMap { $0 }

        movie.movieData = TSP_DataReference.with { $0.identifier = info.identifier }
        movie.startTime = 0
        movie.endTime = Float(media.duration)
        movie.posterTime = 0
        movie.clearFingerprint()
        var posterName: String?
        if let poster, let posterFile, let size = media.videoSize {
            let posterInfo = Self.newDataInfo(poster, stem: "posterImage", extension: posterFile.fileExtension, in: metadata, after: info.identifier)
            new.append((posterInfo, poster))
            posterName = posterInfo.fileName
            movie.posterImageData = TSP_DataReference.with { $0.identifier = posterInfo.identifier }
            let natural = TSP_Size.with { $0.width = Float(size.width); $0.height = Float(size.height) }
            movie.naturalSize = natural
            movie.originalSize = natural
        }
        try replacePayload(of: object, with: try movie.serializedData(partial: true))
        let removed = try commitData(new, replacing: old, metadata: &metadata)
        return MediaReplaceReport(object: object, fileName: info.fileName, posterFileName: posterName, duration: media.duration,
                                  removedData: removed.data, removedFiles: removed.files)
    }
}
