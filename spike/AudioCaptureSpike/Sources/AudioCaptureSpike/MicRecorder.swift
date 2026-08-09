import AVFoundation
import Foundation

/// Microphone capture, kept as a stream entirely separate from system audio.
///
/// Keeping the two apart is what buys us free "Me vs. Them" speaker attribution
/// without any diarization model: whatever arrives on the mic is the user, and
/// whatever arrives on the tap is everyone else.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private(set) var format: AVAudioFormat?

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CaptureError.message(
                "Microphone reported a zero sample rate — permission is probably denied")
        }
        format = inputFormat
        print(
            "  mic format: \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch"
        )

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            handler(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
