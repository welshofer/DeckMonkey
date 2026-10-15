// swift-tools-version:6.0
import PackageDescription

// DeckMonkey — a Swift library that reads and writes native Keynote (.key) files.
// Layers (dependencies point strictly downward; see CLAUDE.md and docs/spec.md §6):
//   IWASnappy   → nothing
//   IWAContainer → Rostrum (zip layer only)
//   IWAArchive  → IWASnappy
//   IWASchema   → SwiftProtobuf (generated per pinned Keynote version)
//   KeynoteGraph → IWAArchive, IWASchema, IWAContainer
//   DeckMonkey  → KeynoteGraph, Rostrum (Deck IR)
//   DeckMonkeyCLI → DeckMonkey (the `deckmonkey` executable, the acceptance surface). The target
//                 and its directory avoid the name `deckmonkey`: on a case-insensitive macOS volume
//                 it collides with the `DeckMonkey` library's source and build directories.
let package = Package(
    name: "DeckMonkey",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "DeckMonkey", targets: ["DeckMonkey"]),
        .executable(name: "deckmonkey", targets: ["DeckMonkeyCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/welshofer/rostrum.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "IWASnappy"),
        .target(
            name: "IWAContainer",
            dependencies: [.product(name: "Rostrum", package: "rostrum")]),
        .target(name: "IWAArchive", dependencies: ["IWASnappy"]),
        .target(
            name: "IWASchema",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            resources: [.copy("Registry")]),
        .target(
            name: "KeynoteGraph",
            dependencies: ["IWAArchive", "IWASchema", "IWAContainer", .product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(
            name: "DeckMonkey",
            dependencies: ["KeynoteGraph", "IWAArchive", "IWAContainer", "IWASchema", "IWASnappy", .product(name: "Rostrum", package: "rostrum"),
                           .product(name: "LecternIR", package: "rostrum"), .product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .executableTarget(name: "DeckMonkeyCLI", dependencies: ["DeckMonkey"], path: "Sources/DeckMonkeyCLI"),
        .testTarget(name: "IWASnappyTests", dependencies: ["IWASnappy"]),
        .testTarget(name: "IWAArchiveTests", dependencies: ["IWAArchive", "IWASnappy"]),
        .testTarget(
            name: "IWASchemaTests",
            dependencies: ["IWASchema", .product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .testTarget(
            name: "IWAContainerTests",
            dependencies: ["IWAContainer", .product(name: "Rostrum", package: "rostrum")]),
        .testTarget(
            name: "KeynoteGraphTests",
            dependencies: ["KeynoteGraph", "IWAArchive", "IWASnappy", "IWAContainer", "IWASchema", .product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        // Fixtures are read through #filePath, not Bundle.module, so they are excluded, not copied.
        .testTarget(name: "DeckMonkeyTests", dependencies: ["DeckMonkey", "IWASnappy"], exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
