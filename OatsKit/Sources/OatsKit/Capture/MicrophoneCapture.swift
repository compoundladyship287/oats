import AVFoundation
import Foundation

/// Captures the user's own voice, kept deliberately separate from the system
/// audio stream. That separation is what gives Oats "Me / Them" labelling with
/// no diarization model at all.
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    public private(set) var format: AVAudioFormat?
    /// Whether the OS echo canceller actually engaged.
    public private(set) var voiceProcessingEnabled = false

    public init() {}

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static var hasAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// - Parameter echoCancellation: Enables the OS voice-processing unit, which
    ///   subtracts the system's own output from the microphone signal. Without
    ///   it, a user on speakers has every remote utterance transcribed twice —
    ///   once correctly as "Them" and once, via the mic, as "Me".
    public func start(
        echoCancellation: Bool = true,
        handler: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        let input = engine.inputNode

        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                // Not fatal: some aggregate/virtual input devices refuse it. The
                // transcript stays usable, just echo-prone on speakers.
                voiceProcessingEnabled = false
            }
            voiceProcessingEnabled = input.isVoiceProcessingEnabled
        }

        // Read the format only after voice processing is enabled — turning it on
        // changes the input node's output format.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CaptureError.message(
                "Microphone reported a zero sample rate — permission is likely denied")
        }
        format = inputFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            handler(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit { stop() }
}
