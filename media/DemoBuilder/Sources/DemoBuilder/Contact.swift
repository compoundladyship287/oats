import AVFoundation
import AppKit

/// Dumps a contact sheet of frames so the cut points can be chosen by looking
/// at the footage rather than guessing at timings.
///
///     DemoBuilder contact <input.mov> <outDir> [everyNSeconds]
enum Contact {
    static func run(input: URL, outputDirectory: URL, every seconds: Double) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 960, height: 540)

        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        var t = 0.0
        while t < duration {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    let name = String(format: "t%05.1f.png", t)
                    try data.write(to: outputDirectory.appendingPathComponent(name))
                }
            }
            t += seconds
        }
        print("wrote frames every \(seconds)s across \(String(format: "%.1f", duration))s")
    }
}
