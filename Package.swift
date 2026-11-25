// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Chrupio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Chrupio", targets: ["Chrupio"]),
        .executable(name: "chrupio-mcp", targets: ["ChrupioMCP"]),
        .library(name: "ChrupioCore", targets: ["ChrupioCore"]),
        .library(name: "ChrupioAudio", targets: ["ChrupioAudio"]),
    ],
    dependencies: [
        // On-device diarization, speaker embeddings and echo removal (CoreML). No traits: the text-normalization
        // engine it links by default is only for speech synthesis.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
        // In-app updates from the appcast on GitHub Releases. Only the app links it; scripts/build-app.sh embeds
        // Sparkle.framework in Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Catches Objective-C exceptions AVFoundation raises (installTap during a device change).
        .target(name: "ChrupioObjC"),
        .target(name: "ChrupioCore", dependencies: ["ChrupioObjC"]),
        // Kept apart so the MCP helper stays small and starts fast.
        .target(name: "ChrupioAudio", dependencies: ["ChrupioCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(
            name: "Chrupio",
            dependencies: ["ChrupioCore", "ChrupioAudio", .product(name: "Sparkle", package: "Sparkle")],
            resources: [.copy("Fonts")],
            // Finds Sparkle.framework in Chrupio.app/Contents/Frameworks; SwiftPM's own rpath covers swift run and tests.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "ChrupioMCP", dependencies: ["ChrupioCore"]),
        .testTarget(name: "ChrupioCoreTests", dependencies: ["ChrupioCore", "ChrupioObjC"]),
        // Runs the CoreML engines on real audio; skipped unless pointed at a recording.
        .testTarget(name: "ChrupioAudioTests", dependencies: ["ChrupioAudio", "ChrupioCore"]),
    ]
)
