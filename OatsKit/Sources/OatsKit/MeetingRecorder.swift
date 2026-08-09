import AVFoundation
import Foundation

/// Runs a meeting end to end: both audio streams in, one merged transcript out.
///
/// The microphone feeds the "Me" channel and the system-audio tap feeds "Them",
/// each with its own on-device transcriber, so speaker attribution falls out of
/// the capture topology instead of a diarization model.
@available(macOS 26.0, *)
public final class MeetingRecorder: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case recording
        case finished
    }

    private let tap = SystemAudioTap()
    private let microphone = MicrophoneCapture()
    private var systemChannel: SpeechChannel?
    private var microphoneChannel: SpeechChannel?

    private let lock = NSLock()
    private var collected: [TranscriptSegment] = []

    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?
    public private(set) var microphoneAvailable = false

    /// Called on an arbitrary thread as each final segment lands.
    public var onSegment: (@Sendable (TranscriptSegment) -> Void)?

    public var systemAudioDevice: String { tap.outputDeviceName }
    public var frameLossFraction: Double { tap.frameLossFraction }

    public init() {}

    public func start(locale: Locale) async throws {
        guard state == .idle else { return }

        microphoneAvailable = await MicrophoneCapture.requestAccess()

        let collect: @Sendable (TranscriptSegment) -> Void = { [weak self] segment in
            guard let self else { return }
            self.lock.lock()
            self.collected.append(segment)
            self.lock.unlock()
            self.onSegment?(segment)
        }

        // Prepare the tap before starting anything: building the aggregate
        // device is the slow step, and starting the mic first would skew the
        // two channels' timelines relative to each other.
        try tap.prepare()

        systemChannel = try await SpeechChannel.make(
            speaker: .them, locale: locale, onSegment: collect)
        if microphoneAvailable {
            microphoneChannel = try await SpeechChannel.make(
                speaker: .me, locale: locale, onSegment: collect)
        }

        // One origin shared by both channels, established before either starts.
        let origin = Date()
        systemChannel?.start(origin: origin)
        microphoneChannel?.start(origin: origin)

        startedAt = origin
        state = .recording

        if microphoneAvailable, let channel = microphoneChannel {
            // Echo cancellation stays off: the OS voice-processing unit cannot
            // coexist with the process tap. See `MicrophoneCapture.start`.
            // Speaker bleed is removed downstream by `Transcript.withoutEcho()`.
            try microphone.start { buffer in channel.ingest(buffer) }
        }
        if let channel = systemChannel {
            try tap.start { buffer in channel.ingest(buffer) }
        }
    }

    /// Stops capture, drains both transcribers, and returns the merged
    /// transcript ordered by time.
    public func stop() async -> Transcript {
        guard state == .recording else { return currentTranscript() }
        state = .finished

        tap.stop()
        microphone.stop()

        await systemChannel?.finish()
        await microphoneChannel?.finish()
        systemChannel = nil
        microphoneChannel = nil

        return currentTranscript()
    }

    public func currentTranscript() -> Transcript {
        lock.lock()
        let segments = collected
        lock.unlock()

        var transcript = Transcript()
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            transcript.insert(segment)
        }
        return transcript.withoutEcho()
    }
}
