// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioCaptureSpike",
    // 14.2 is where AudioHardwareCreateProcessTap lands; 14.4 adds the
    // lighter "System Audio Recording Only" permission we actually want.
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "AudioCaptureSpike",
            path: "Sources/AudioCaptureSpike",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Embed an Info.plist directly into the Mach-O so TCC can read
                // NSAudioCaptureUsageDescription / NSMicrophoneUsageDescription
                // for a bare SwiftPM executable (no .app bundle).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AudioCaptureSpike/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "TranscribeSpike",
            path: "Sources/TranscribeSpike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
