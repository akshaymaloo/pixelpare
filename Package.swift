// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PixelPare",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "PareCore", targets: ["PareCore"]),
        .library(name: "PareVision", targets: ["PareVision"]),
        .library(name: "PareLibrary", targets: ["PareLibrary"]),
        .library(name: "PareTranscode", targets: ["PareTranscode"]),
        .library(name: "PareUI", targets: ["PareUI"]),
    ],
    targets: [
        .target(name: "PareCore"),
        .target(name: "PareVision", dependencies: ["PareCore"]),
        .target(name: "PareLibrary", dependencies: ["PareCore"]),
        .target(name: "PareTranscode", dependencies: ["PareCore"]),
        .target(name: "PareUI", dependencies: ["PareLibrary", "PareVision", "PareTranscode"]),
        .testTarget(name: "PareCoreTests", dependencies: ["PareCore"]),
        .testTarget(name: "PareVisionTests", dependencies: ["PareVision", "PareCore"]),
        .testTarget(name: "PareLibraryTests", dependencies: ["PareLibrary", "PareCore"]),
        .testTarget(name: "PareTranscodeTests", dependencies: ["PareTranscode", "PareCore"]),
    ],
    swiftLanguageModes: [.v6]
)
