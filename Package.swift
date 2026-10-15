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
//   deckmonkey  → DeckMonkey (CLI, the acceptance surface; lives in Sources/deckmonkey-cli because
//                 macOS is case-insensitive and would merge it with Sources/DeckMonkey)
let package = Package(
    name: "DeckMonkey",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "DeckMonkey", targets: ["DeckMonkey"]),
        .executable(name: "deckmonkey", targets: ["deckmonkey"]),
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
            dependencies: ["IWAArchive", "IWASchema", "IWAContainer"]),
        .target(
            name: "DeckMonkey",
            dependencies: ["KeynoteGraph", "IWAArchive", "IWAContainer", .product(name: "Rostrum", package: "rostrum")]),
        .executableTarget(name: "deckmonkey", dependencies: ["DeckMonkey"], path: "Sources/deckmonkey-cli"),
        .testTarget(name: "IWASnappyTests", dependencies: ["IWASnappy"]),
        .testTarget(name: "IWAArchiveTests", dependencies: ["IWAArchive", "IWASnappy"]),
        .testTarget(
            name: "IWAContainerTests",
            dependencies: ["IWAContainer", .product(name: "Rostrum", package: "rostrum")]),
        .testTarget(name: "KeynoteGraphTests", dependencies: ["KeynoteGraph", "IWAArchive", "IWASnappy", "IWAContainer"]),
    ],
    swiftLanguageModes: [.v6]
)
