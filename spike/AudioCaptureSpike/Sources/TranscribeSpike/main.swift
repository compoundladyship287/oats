import AVFoundation
import Foundation
import Speech

// M1 spike: transcribe a captured WAV entirely on-device using Apple's
// SpeechAnalyzer (macOS 26+).
//
// If this is accurate enough, Oats gets a transcription tier that needs no
// model download, no Python, and no bundled weights — a strong default for
// Macs on macOS 26, with Parakeet/whisper.cpp as the portable fallback.
//
//   swift run TranscribeSpike <path-to.wav> [locale]

@available(macOS 26.0, *)
func transcribe(url audioURL: URL, localeIdentifier: String) async throws -> Int32 {
    print("Oats — on-device transcription spike")
    print(String(repeating: "─", count: 52))
    print("file:   \(audioURL.lastPathComponent)")

    let file = try AVAudioFile(forReading: audioURL)
    let audioDuration = Double(file.length) / file.fileFormat.sampleRate
    print(
        "audio:  \(String(format: "%.1f", audioDuration))s, "
            + "\(Int(file.fileFormat.sampleRate)) Hz, \(file.fileFormat.channelCount) ch")

    guard SpeechTranscriber.isAvailable else {
        print("SpeechTranscriber reports unavailable on this machine.")
        return 1
    }

    let requested = Locale(identifier: localeIdentifier)
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
        let supported = await SpeechTranscriber.supportedLocales
        print("locale \(localeIdentifier) unsupported. Supported: \(supported.map(\.identifier))")
        return 1
    }
    let installed = await SpeechTranscriber.installedLocales
    print("locale: \(locale.identifier) (already installed: \(installed.contains(locale)))")

    // Ask for time ranges so we can align transcript segments with the notepad
    // and, later, with diarization output.
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
    )

    // The only network access in this whole program: a one-time OS-level model
    // asset install. Audio and text never leave the machine.
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        print("installing speech model assets (one time)…")
        try await request.downloadAndInstall()
        print("assets installed")
    } else {
        print("assets: already present, no download needed")
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    let collector = Task { () -> [(CMTimeRange, String)] in
        var segments: [(CMTimeRange, String)] = []
        for try await result in transcriber.results {
            segments.append((result.range, String(result.text.characters)))
        }
        return segments
    }

    print("\ntranscribing…")
    let started = Date()
    _ = try await analyzer.analyzeSequence(from: file)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let segments = try await collector.value
    let elapsed = Date().timeIntervalSince(started)

    print(String(repeating: "─", count: 52))
    var wordCount = 0
    if segments.isEmpty {
        print("No transcript produced.")
    } else {
        for (range, text) in segments {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            wordCount += trimmed.split(separator: " ").count
            print(
                String(
                    format: "[%6.2f → %6.2f]  %@",
                    CMTimeGetSeconds(range.start), CMTimeGetSeconds(range.end), trimmed))
        }
    }
    print(String(repeating: "─", count: 52))
    print(
        String(
            format: "%.2fs of audio in %.2fs  →  %.0fx realtime   (%d words)",
            audioDuration, elapsed, audioDuration / max(elapsed, 0.0001), wordCount))
    return segments.isEmpty ? 1 : 0
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: TranscribeSpike <path-to.wav> [locale]")
    exit(2)
}

if #available(macOS 26.0, *) {
    let status = try await transcribe(
        url: URL(fileURLWithPath: arguments[1]),
        localeIdentifier: arguments.count > 2 ? arguments[2] : "en-US")
    exit(status)
} else {
    print("SpeechAnalyzer needs macOS 26 or newer — the portable path would use whisper.cpp here.")
    exit(1)
}
