import AVFoundation
import Foundation

// M0 capture spike. Proves the single riskiest assumption behind Oats: that we
// can record system audio and the microphone as two clean, separate streams on
// this Mac, with no bot in the meeting and no virtual audio driver installed.
//
//   swift run AudioCaptureSpike [seconds] [output-directory]

let arguments = CommandLine.arguments
let duration = arguments.count > 1 ? (Double(arguments[1]) ?? 10) : 10
let outputDirectory =
    arguments.count > 2
    ? URL(fileURLWithPath: arguments[2])
    : FileManager.default.temporaryDirectory.appendingPathComponent("oats-spike")

try? FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true)

print("Oats — system audio + microphone capture spike")
print(String(repeating: "─", count: 52))
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("duration: \(duration)s   output: \(outputDirectory.path)\n")

// ── Set up both streams before starting either ───────────────────────────────
// Building the aggregate device takes a moment, so prepare first and start the
// two streams back to back; otherwise their durations aren't comparable.
print("microphone")
let micGranted = await MicRecorder.requestAccess()
print("  permission: \(micGranted ? "granted" : "DENIED")")
let mic = MicRecorder()

print("\nsystem audio (Core Audio process tap)")
let tap = SystemAudioTap()
var tapWriter: WAVWriter?
var micWriter: WAVWriter?
var tapFailure: String?

do {
    try tap.prepare()
    if let format = tap.format {
        tapWriter = WAVWriter(
            url: outputDirectory.appendingPathComponent("system.wav"),
            format: format,
            expectedSeconds: duration + 10)
    }
} catch {
    tapFailure = "\(error)"
    print("  FAILED: \(error)")
}

if micGranted {
    do {
        try mic.start { buffer in micWriter?.append(buffer) }
        if let format = mic.format {
            micWriter = WAVWriter(
                url: outputDirectory.appendingPathComponent("mic.wav"), format: format)
        }
    } catch {
        print("  microphone could not start: \(error)")
    }
}

if tapFailure == nil {
    do {
        try tap.start { buffer in tapWriter?.append(buffer) }
        print("  capturing…")
    } catch {
        tapFailure = "\(error)"
        print("  FAILED to start: \(error)")
    }
}

// ── Run ──────────────────────────────────────────────────────────────────────
print("\nRecording for \(Int(duration))s — play something and talk, so both streams have signal.")
let deadline = Date().addingTimeInterval(duration)
while Date() < deadline {
    try? await Task.sleep(for: .milliseconds(500))
    let systemLevel = tapWriter.map { WAVWriter.dBFS($0.peak) } ?? "n/a"
    let micLevel = micWriter.map { WAVWriter.dBFS($0.peak) } ?? "n/a"
    let remaining = max(0, Int(deadline.timeIntervalSinceNow))
    print(
        "\r  \(remaining)s left   system peak \(systemLevel) dBFS   mic peak \(micLevel) dBFS    ",
        terminator: "")
    fflush(stdout)
}
print("\n")

tap.stop()
mic.stop()

// ── Verdict ──────────────────────────────────────────────────────────────────
// Exiting cleanly proves nothing: the documented tap failures all return noErr
// and hand back silence. Signal level is the only real check, and it is tracked
// separately from whether the file happened to write.
print(String(repeating: "─", count: 52))

enum StreamOutcome {
    case noFrames
    case silent
    case captured
}

func report(_ label: String, _ writer: WAVWriter?) -> StreamOutcome {
    guard let writer, writer.frameCount > 0 else {
        print("\(label): no frames captured")
        return .noFrames
    }
    let silent = writer.peak < 1e-6
    print(
        "\(label): \(String(format: "%.1f", writer.durationSeconds))s   "
            + "peak \(WAVWriter.dBFS(writer.peak)) dBFS   rms \(WAVWriter.dBFS(writer.rms)) dBFS"
            + (silent ? "   ← SILENT (frames flowed but every sample is zero)" : ""))
    do {
        try writer.close()
        print("         wrote \(writer.url.lastPathComponent)")
    } catch {
        print("         write failed: \(error)")
    }
    return silent ? .silent : .captured
}

let systemOutcome = report("system", tapWriter)
let micOutcome = report("mic   ", micWriter)

if tap.callbackCount > 0 {
    let expected = tap.deliveredFrames + tap.missingFrames
    let lossPercent = expected > 0 ? (tap.missingFrames / expected) * 100 : 0
    print(
        String(
            format: "        tap: %d callbacks, %.0f frames delivered, %.0f missing (%.2f%% loss)",
            tap.callbackCount, tap.deliveredFrames, tap.missingFrames, lossPercent))
}

print(String(repeating: "─", count: 52))
if let tapFailure {
    print("RESULT: system audio tap could not start — \(tapFailure)")
} else {
    switch (systemOutcome, micOutcome) {
    case (.captured, .captured):
        print("RESULT: both streams captured real audio. M0 assumption holds.")
    case (.captured, _):
        print("RESULT: system audio works; mic did not (check permission / input device).")
    case (.silent, _):
        print("RESULT: tap ran but every sample was zero — check the permission grant.")
    case (.noFrames, _):
        print("RESULT: tap started but delivered no buffers.")
    }
}
print("files: \(outputDirectory.path)")
