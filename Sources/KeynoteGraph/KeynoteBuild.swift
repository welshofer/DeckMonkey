import Foundation

/// One entry of `Metadata/BuildVersionHistory.plist`: the Keynote build that saved the file.
///
/// Shapes seen in the corpus (CLAUDE.md, first contact):
///   `M15.4-7051.0.79-2`  macOS — M, marketing version, build, save count
///   `M6.5-2109-1`        macOS, older build numbering
///   `T2.5.1 (1715)`      Keynote for iOS, its own version line
///   `G-r11-2A396`        Keynote for iCloud, no marketing version at all
/// Only macOS stamps are comparable with the pinned schema version (AT-25); the others are
/// recorded and left alone.
public struct KeynoteBuild: Sendable, Equatable, CustomStringConvertible {
    public enum Platform: String, Sendable {
        case macOS = "M"
        case iOS = "T"
        case iCloud = "G"
        case unknown = "?"
    }

    public let raw: String
    public let platform: Platform
    /// Marketing version components, e.g. `[15, 4]`; nil when the stamp carries none.
    public let version: [Int]?

    public init(raw: String, platform: Platform, version: [Int]?) {
        self.raw = raw
        self.platform = platform
        self.version = version
    }

    public var description: String { raw }

    public static func parse(_ raw: String) -> KeynoteBuild {
        let stamp = raw.trimmingCharacters(in: .whitespaces)
        guard let first = stamp.first, let platform = Platform(rawValue: String(first)) else {
            return KeynoteBuild(raw: raw, platform: .unknown, version: nil)
        }
        let rest = stamp.dropFirst()
        // The marketing version runs from the platform letter to the first '-' or ' '.
        let versionText = rest.prefix { $0 != "-" && $0 != " " }
        var version: [Int]?
        if platform != .iCloud {
            let parts = versionText.split(separator: ".")
            let numbers = parts.compactMap { Int($0) }
            if !numbers.isEmpty, numbers.count == parts.count {
                version = numbers
            }
        }
        return KeynoteBuild(raw: raw, platform: platform, version: version)
    }

    /// Dotted version components, e.g. "15.4" → `[15, 4]`.
    public static func versionComponents(_ text: String) -> [Int] {
        text.split(separator: ".").compactMap { Int($0) }
    }

    /// Lexicographic comparison of version component arrays; shorter arrays are padded with zeros.
    public static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Whether this is a macOS build whose marketing version is above `pinned` (e.g. "15.4").
    public func isNewer(thanPinned pinned: String) -> Bool {
        guard platform == .macOS, let version else { return false }
        return Self.compare(version, Self.versionComponents(pinned)) == .orderedDescending
    }
}
