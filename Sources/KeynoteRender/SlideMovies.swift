import Foundation
import IWASchema
import KeynoteGraph

/// A movie or audio clip on a slide, as a host plays it over the slide's picture (the renderer
/// draws its poster frame).
public struct SlideMovie: Sendable, Equatable {
    public enum Loop: Sendable, Equatable { case none, repeating, backAndForth }

    public var id: UInt64
    /// The unrotated frame in slide points, and its rotation (degrees, counter-clockwise).
    public var x: Double, y: Double, width: Double, height: Double
    public var angle: Double
    /// The movie's file in the package's `Data/` folder.
    public var fileName: String
    /// Where playback starts and stops, in seconds (`end` nil: the movie's own end).
    public var start: Double
    public var end: Double?
    public var poster: Double
    public var loop: Loop
    /// 0…1.
    public var volume: Double
    /// Keynote's "Start movie automatically".
    public var autoPlay: Bool
    /// Audio with no picture (a sound clip's icon is not shown while presenting).
    public var audioOnly: Bool
    /// A "Start Movie" build starts it (a click, or the build's own timing), not the slide.
    public var startsOnBuild: Bool
}

extension KeynoteRenderer {
    /// The movies and sound clips on `slide`, in z-order.
    public func movies(onSlide slide: UInt64) -> [SlideMovie] {
        guard let archive = document.decoded(KN_SlideArchive.self, slide) else { return [] }
        // Movies a "Start Movie" build plays.
        var started = Set<UInt64>()
        for ref in archive.builds.prefix(2_000) {
            if let build = document.decoded(KN_BuildArchive.self, ref.identifier), build.hasDrawable,
               build.attributes.animationAttributes.effect == "apple:movie-start" {
                started.insert(build.drawable.identifier)
            }
        }
        return drawables(onSlide: slide).compactMap { d -> SlideMovie? in
            guard d.kind == .movie, let movie = document.decoded(TSD_MovieArchive.self, d.id), movie.hasMovieData,
                  let fileName = movieFileName(movie.movieData.identifier) else { return nil }
            let loop: SlideMovie.Loop
            switch movie.loopOption {
            case .repeat: loop = .repeating
            case .backAndForth: loop = .backAndForth
            default: loop = .none
            }
            let end = movie.hasEndTime && movie.endTime > movie.startTime ? Double(movie.endTime) : nil
            return SlideMovie(id: d.id, x: d.x, y: d.y, width: d.width, height: d.height, angle: d.angle, fileName: fileName,
                              start: max(0, Double(movie.startTime)), end: end, poster: Double(movie.posterTime), loop: loop,
                              volume: movie.hasVolume ? max(0, min(1, Double(movie.volume))) : 1, autoPlay: movie.autoPlay,
                              audioOnly: movie.audioOnly, startsOnBuild: started.contains(d.id))
        }
    }

    /// The bytes of `movie`'s file (mapped with the deck when the deck was opened mapped).
    public func movieData(_ movie: SlideMovie) -> Data? {
        document.package.data("Data/" + movie.fileName)
    }

    /// The name of a movie's file in `Data/`, if the file holds it.
    func movieFileName(_ id: UInt64) -> String? {
        guard let info = document.packageMetadata?.datas.first(where: { $0.identifier == id }),
              let name = info.storedFileName, document.package.data("Data/" + name) != nil else { return nil }
        return name
    }
}
