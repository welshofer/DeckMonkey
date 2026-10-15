// swift-tools-version:6.0
import PackageDescription

// Schema tooling (docs/spec.md §7, Scripts/schema/README.md). macOS only, never a dependency of
// the library: it reads the installed Keynote. swift-protobuf is pinned to the exact version the
// library resolves, so protoc-gen-swift built here emits code for the runtime IWASchema links.
let package = Package(
    name: "SchemaTools",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
    ],
    targets: [
        .executableTarget(
            name: "protodump",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
