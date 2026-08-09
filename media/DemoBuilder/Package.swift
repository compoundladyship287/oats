// swift-tools-version: 6.0
import PackageDescription

// Builds the demo video from a real screen recording plus rendered titles and
// captions. AVFoundation only — no ffmpeg, no dependencies, consistent with the
// rest of the project.
let package = Package(
    name: "DemoBuilder",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(name: "DemoBuilder", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
