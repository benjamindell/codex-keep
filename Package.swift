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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.2")
    ],
    targets: [
        .target(
            name: "CodexKeepCore"
        ),
        .executableTarget(
            name: "CodexKeepApp",
            dependencies: [
                "CodexKeepCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "CodexKeepTests",
            dependencies: ["CodexKeepCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
