import AVFoundation
import AppKit
import QuartzCore

/// Assembles the demo film: a jump-cut edit of the raw take with a moving
/// camera, captions, a title and an outro. Target length ~40s.
///
/// The camera is the edit's voice. Each shot names a source span and where the
/// virtual camera looks — full frame, a static close-up, or a push between two
/// rects. Zooming is what lets a 95-second take (mostly model loading and
/// transcription drain) read as a brisk 40-second tour: the cuts skip the
/// waiting, the camera supplies the motion that makes the jumps feel deliberate.
enum DemoFilm {

    // MARK: - The edit

    struct Shot {
        let start: Double
        let end: Double
        let caption: String?
        /// Where the camera looks, in raw-capture pixels. nil = the full window.
        var zoomFrom: CGRect?
        var zoomTo: CGRect?
        var duration: Double { end - start }
    }

    /// The raw capture IS the window: record-demo.sh captures the window rect
    /// exactly, so the desktop never appears and every camera rect scales
    /// uniformly (1280x720 points = 2560x1440 pixels, exactly 16:9).
    static let window = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    /// Timings are raw-capture seconds; the comments track record-demo.sh.
    /// Verified against a contact sheet, not guessed.
    static let shots: [Shot] = [
        // Onboarding, from the very top.
        Shot(start: 1.2, end: 3.6, caption: "Set up in a minute",
             zoomFrom: window, zoomTo: rect(centerX: 1280, centerY: 660, width: 2240)),
        Shot(start: 6.6, end: 9.2, caption: "It asks for exactly what it needs",
             zoomFrom: rect(centerX: 1280, centerY: 700, width: 1800),
             zoomTo: rect(centerX: 1280, centerY: 700, width: 1580)),
        // Home.
        Shot(start: 15.2, end: 17.2, caption: "Ready to record",
             zoomFrom: window, zoomTo: window),
        // Naming the meeting (the sheet lives briefly; keep the shot tight).
        Shot(start: 18.0, end: 19.4, caption: "Name it, hit record",
             zoomFrom: rect(centerX: 1280, centerY: 640, width: 1440),
             zoomTo: rect(centerX: 1280, centerY: 640, width: 1360)),
        // Live: rough notes while the far side talks.
        Shot(start: 44.0, end: 50.0, caption: "Type rough fragments while you talk",
             zoomFrom: rect(centerX: 1150, centerY: 430, width: 1760),
             zoomTo: rect(centerX: 1150, centerY: 430, width: 1520)),
        // Live: the transcript filling itself in.
        Shot(start: 51.5, end: 57.5, caption: "Both sides transcribed on-device",
             zoomFrom: rect(centerX: 2140, centerY: 470, width: 1400),
             zoomTo: rect(centerX: 2140, centerY: 470, width: 1220)),
        // The pill floating over Finder.
        Shot(start: 63.0, end: 67.0, caption: "Controls float over any app",
             zoomFrom: rect(centerX: 1990, centerY: 330, width: 1560),
             zoomTo: rect(centerX: 1990, centerY: 330, width: 1180)),
        // Pause / resume.
        Shot(start: 70.5, end: 74.0, caption: "Pause without leaving a gap",
             zoomFrom: window, zoomTo: window),
        // The payoff: written-up notes.
        Shot(start: 97.5, end: 104.5, caption: "Your outline, filled in with what was said",
             zoomFrom: window, zoomTo: rect(centerX: 1350, centerY: 620, width: 2060)),
    ]

    static let titleDuration = 2.8
    static let outroDuration = 4.4

    // MARK: - Geometry

    static let renderSize = CGSize(width: 1920, height: 1080)

    /// A 16:9 camera rect from a centre and width, clamped inside the window.
    static func rect(centerX: CGFloat, centerY: CGFloat, width: CGFloat) -> CGRect {
        let height = width * 9 / 16
        var r = CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
        if r.minX < window.minX { r.origin.x = window.minX }
        if r.minY < window.minY { r.origin.y = window.minY }
        if r.maxX > window.maxX { r.origin.x = window.maxX - width }
        if r.maxY > window.maxY { r.origin.y = window.maxY - height }
        return r
    }

    private static let background = NSColor(srgbRed: 0.055, green: 0.06, blue: 0.07, alpha: 1)
    private static let cream = NSColor(srgbRed: 0.99, green: 0.93, blue: 0.79, alpha: 1)
    private static let amber = NSColor(srgbRed: 0.91, green: 0.74, blue: 0.40, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.26, green: 0.17, blue: 0.08, alpha: 1)

    // MARK: - Build

    static func build(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure("no video track in \(input.lastPathComponent)")
        }

        let composition = AVMutableComposition()
        guard
            let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure("could not create a composition track") }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)

        var cursor = CMTime(seconds: titleDuration, preferredTimescale: 600)
        var captionSpans: [(caption: String, start: Double, end: Double)] = []

        for shot in shots {
            let range = CMTimeRange(
                start: CMTime(seconds: shot.start, preferredTimescale: 600),
                duration: CMTime(seconds: shot.duration, preferredTimescale: 600))
            try track.insertTimeRange(range, of: sourceTrack, at: cursor)

            let compositionRange = CMTimeRange(start: cursor, duration: range.duration)
            let from = shot.zoomFrom ?? window
            let to = shot.zoomTo ?? from
            if from == to {
                layerInstruction.setTransform(transform(for: from), at: cursor)
            } else {
                // A linear matrix ramp is fine for same-aspect scale+translate:
                // it renders as a steady push, which is all these shots want.
                layerInstruction.setTransformRamp(
                    fromStart: transform(for: from), toEnd: transform(for: to),
                    timeRange: compositionRange)
            }

            if let caption = shot.caption {
                captionSpans.append(
                    (caption, cursor.seconds + 0.15, cursor.seconds + shot.duration - 0.15))
            }
            cursor = cursor + range.duration
        }

        let footageEnd = cursor.seconds
        let total = footageEnd + outroDuration

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero, duration: CMTime(seconds: total, preferredTimescale: 600))
        instruction.layerInstructions = [layerInstruction]
        instruction.backgroundColor = background.cgColor

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        // Overlay: framed footage, title, captions, outro.
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.backgroundColor = background.cgColor

        let videoFrame = CGRect(x: 96, y: 84, width: 1728, height: 972)
        let videoShadow = CALayer()
        videoShadow.frame = videoFrame
        videoShadow.cornerRadius = 16
        videoShadow.cornerCurve = .continuous
        videoShadow.backgroundColor = NSColor.black.cgColor
        videoShadow.shadowColor = NSColor.black.cgColor
        videoShadow.shadowOpacity = 0.55
        videoShadow.shadowRadius = 40
        videoShadow.shadowOffset = CGSize(width: 0, height: -14)
        videoShadow.opacity = 0
        parent.addSublayer(videoShadow)

        let videoLayer = CALayer()
        videoLayer.frame = videoFrame
        videoLayer.cornerRadius = 16
        videoLayer.cornerCurve = .continuous
        videoLayer.masksToBounds = true
        videoLayer.opacity = 0
        parent.addSublayer(videoLayer)

        fade(videoLayer, visibleFrom: titleDuration - 0.3, to: footageEnd + 0.15, total: total)
        fade(videoShadow, visibleFrom: titleDuration - 0.3, to: footageEnd + 0.15, total: total)

        let title = titleLayer()
        parent.addSublayer(title)
        fade(title, visibleFrom: 0, to: titleDuration - 0.2, total: total, fadeIn: 0.45)

        for span in captionSpans {
            let layer = captionLayer(span.caption)
            parent.addSublayer(layer)
            fade(layer, visibleFrom: span.start, to: span.end, total: total, fadeIn: 0.3)
        }

        let outro = outroLayer()
        parent.addSublayer(outro)
        fade(outro, visibleFrom: footageEnd + 0.1, to: total, total: total, fadeIn: 0.45)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)

        try await export(
            composition: composition, videoComposition: videoComposition, to: output,
            duration: CMTime(seconds: total, preferredTimescale: 600))

        print(String(format: "wrote %@ (%.1fs)", output.path, total))
    }

    /// Maps a camera rect (source pixels) onto the full render canvas. The
    /// videoLayer is a uniform 0.9x of the canvas, so aspect is preserved
    /// end to end.
    private static func transform(for rect: CGRect) -> CGAffineTransform {
        let scale = renderSize.width / rect.width
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(
                CGAffineTransform(translationX: -rect.minX * scale, y: -rect.minY * scale))
    }

    // MARK: - Cards

    private static func titleLayer() -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)
        layer.opacity = 0

        let mark = oatsMark(size: 132)
        mark.frame = CGRect(x: renderSize.width / 2 - 66, y: 620, width: 132, height: 132)
        layer.addSublayer(mark)

        layer.addSublayer(
            text("Oats", font: .systemFont(ofSize: 96, weight: .semibold), color: .white,
                 frame: CGRect(x: 0, y: 470, width: renderSize.width, height: 120)))
        layer.addSublayer(
            text("Meeting notes that never leave your Mac",
                 font: .systemFont(ofSize: 40, weight: .regular),
                 color: NSColor.white.withAlphaComponent(0.72),
                 frame: CGRect(x: 0, y: 396, width: renderSize.width, height: 60)))
        layer.addSublayer(
            text("No cloud   ·   No bot in your call   ·   Plain Markdown you keep",
                 font: .systemFont(ofSize: 26, weight: .medium),
                 color: amber.withAlphaComponent(0.9),
                 frame: CGRect(x: 0, y: 320, width: renderSize.width, height: 40)))
        return layer
    }

    private static func outroLayer() -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)
        layer.opacity = 0

        let mark = oatsMark(size: 104)
        mark.frame = CGRect(x: renderSize.width / 2 - 52, y: 660, width: 104, height: 104)
        layer.addSublayer(mark)

        layer.addSublayer(
            text("Free and open source", font: .systemFont(ofSize: 44, weight: .semibold),
                 color: .white,
                 frame: CGRect(x: 0, y: 560, width: renderSize.width, height: 60)))

        let pill = CALayer()
        let pillWidth: CGFloat = 900
        pill.frame = CGRect(
            x: renderSize.width / 2 - pillWidth / 2, y: 430, width: pillWidth, height: 88)
        pill.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        pill.cornerRadius = 20
        pill.cornerCurve = .continuous
        pill.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        pill.borderWidth = 1
        layer.addSublayer(pill)

        layer.addSublayer(
            text("brew install yuvrajadhikari/oats/oats",
                 font: .monospacedSystemFont(ofSize: 34, weight: .medium), color: cream,
                 frame: CGRect(x: 0, y: 452, width: renderSize.width, height: 46)))
        layer.addSublayer(
            text("github.com/yuvrajadhikari/oats",
                 font: .systemFont(ofSize: 30, weight: .regular),
                 color: NSColor.white.withAlphaComponent(0.66),
                 frame: CGRect(x: 0, y: 344, width: renderSize.width, height: 44)))
        layer.addSublayer(
            text("MIT   ·   macOS 26+   ·   Apple Silicon",
                 font: .systemFont(ofSize: 22, weight: .regular),
                 color: NSColor.white.withAlphaComponent(0.4),
                 frame: CGRect(x: 0, y: 292, width: renderSize.width, height: 34)))
        return layer
    }

    private static func captionLayer(_ string: String) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)
        container.opacity = 0

        let font = NSFont.systemFont(ofSize: 34, weight: .medium)
        let width = (string as NSString).size(withAttributes: [.font: font]).width + 64
        let height: CGFloat = 74

        let pill = CALayer()
        pill.frame = CGRect(
            x: renderSize.width / 2 - width / 2, y: 20, width: width, height: height)
        pill.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        pill.cornerRadius = height / 2
        pill.cornerCurve = .continuous
        pill.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        pill.borderWidth = 1
        container.addSublayer(pill)

        container.addSublayer(
            text(string, font: font, color: .white,
                 frame: CGRect(x: 0, y: 40, width: renderSize.width, height: 44)))
        return container
    }

    /// The Oats mark, same proportions as the app icon.
    private static func oatsMark(size: CGFloat) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: size, height: size)

        let gradient = CAGradientLayer()
        gradient.frame = root.bounds
        gradient.colors = [cream.cgColor, amber.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.cornerRadius = size * 0.2237
        gradient.cornerCurve = .continuous
        root.addSublayer(gradient)

        let heights: [CGFloat] = [0.30, 0.52, 0.40, 0.20]
        let barWidth = size * 0.088
        let gap = size * 0.072
        let total = barWidth * 4 + gap * 3
        var x = size / 2 - total / 2
        for height in heights {
            let bar = CALayer()
            let barHeight = size * height
            bar.frame = CGRect(
                x: x, y: size / 2 - barHeight / 2, width: barWidth, height: barHeight)
            bar.backgroundColor = ink.cgColor
            bar.cornerRadius = barWidth / 2
            root.addSublayer(bar)
            x += barWidth + gap
        }
        return root
    }

    /// Text pre-rendered to a bitmap. CATextLayer is the obvious tool and it
    /// silently rendered nothing in the AVFoundation export — every card and
    /// caption came out as an empty pill. Rasterising with AppKit up front
    /// removes the render-server dependency entirely.
    private static func text(
        _ string: String, font: NSFont, color: NSColor, frame: CGRect
    ) -> CALayer {
        let scale: CGFloat = 2
        let size = NSSize(width: frame.width * scale, height: frame.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font,
            .foregroundColor: color,
        ]
        let measured = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(
            at: NSPoint(x: (size.width - measured.width) / 2,
                        y: (size.height - measured.height) / 2),
            withAttributes: attributes)
        image.unlockFocus()

        let layer = CALayer()
        layer.frame = frame
        var rect = CGRect(origin: .zero, size: size)
        layer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        return layer
    }

    /// Animations added through the animation tool must anchor to
    /// `AVCoreAnimationBeginTimeAtZero` — a literal zero means "now" and the
    /// layer never appears in the export.
    private static func fade(
        _ layer: CALayer, visibleFrom start: Double, to end: Double, total: Double,
        fadeIn: Double = 0.4
    ) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        let fadeOut = 0.35
        let clampedEnd = min(end, total)
        animation.keyTimes = [
            0,
            NSNumber(value: max(0.0001, start / total)),
            NSNumber(value: min(0.9998, (start + fadeIn) / total)),
            NSNumber(
                value: min(
                    0.9999, max((start + fadeIn) / total, (clampedEnd - fadeOut) / total))),
            NSNumber(value: min(1, clampedEnd / total)),
            1,
        ]
        animation.values = [0, 0, 1, 1, 0, 0]
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.duration = total
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "fade")
    }

    // MARK: - Export

    private static func export(
        composition: AVMutableComposition, videoComposition: AVMutableVideoComposition,
        to output: URL, duration: CMTime
    ) async throws {
        try? FileManager.default.removeItem(at: output)
        guard
            let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPreset1920x1080)
        else { throw Failure("could not create an export session") }
        session.videoComposition = videoComposition
        session.timeRange = CMTimeRange(start: .zero, duration: duration)
        try await session.export(to: output, as: .mp4)
    }
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
