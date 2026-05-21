// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "CodexKeep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexKeep", targets: ["CodexKeepApp"]),
        .library(name: "CodexKeepCore", targets: ["CodexKeepCore"])
    ],
    targets: [
        .target(
            name: "CodexKeepCore"
        ),
        .executableTarget(
            name: "CodexKeepApp",
            dependencies: ["CodexKeepCore"]
        ),
        .testTarget(
            name: "CodexKeepTests",
            dependencies: ["CodexKeepCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
