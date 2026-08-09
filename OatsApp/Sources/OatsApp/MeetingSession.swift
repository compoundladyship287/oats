import Foundation
import OatsKit
import Observation

/// The live meeting, as the UI sees it.
///
/// This is the only place the app touches `MeetingRecorder`. It exists because
/// the engine is deliberately UI-agnostic: `onSegment` fires on whatever thread
/// the speech analyzer happens to be on, and SwiftUI needs main-actor state, so
/// something has to own that hop. Keeping it in one class means no view ever has
/// to think about threading.
@MainActor
@Observable
final class MeetingSession {
    enum Phase: Equatable {
        case idle
        /// Building the tap and loading speech models — slow enough to show.
        case starting
        case recording
        /// Draining both transcribers. Bounded, but can take seconds.
        case finishing
        case enhancing
    }

    private(set) var phase: Phase = .idle
    var title: String = ""
    var roughNotes: String = ""
    var templateID: String = NoteTemplate.general.id

    /// Echo-deduplicated, so the panel shows what will actually be saved rather
    /// than the microphone's copy of the far end.
    private(set) var segments: [TranscriptSegment] = []
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var systemAudioDevice = ""
    private(set) var microphoneAvailable = true
    /// Set when a meeting has just been saved, so the library can select it.
    private(set) var lastSaved: Meeting?

    private var recorder: MeetingRecorder?
    private var startedAt = Date()
    private var ticker: Task<Void, Never>?
    private let store: MeetingStore

    init(store: MeetingStore = MeetingStore()) {
        self.store = store
    }

    var isBusy: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    var statusText: String {
        switch phase {
        case .idle: return "Ready"
        case .starting: return "Preparing on-device models…"
        case .recording: return elapsed.clockString
        case .finishing: return "Finishing transcription…"
        case .enhancing: return "Writing your notes…"
        }
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        errorMessage = nil
        lastSaved = nil
        segments = []
        elapsed = 0

        let recorder = MeetingRecorder()
        recorder.onSegment = { [weak self] _ in
            // Audio-thread adjacent: hop before touching any observable state.
            Task { @MainActor [weak self] in self?.refreshSegments() }
        }
        self.recorder = recorder

        do {
            let locale = try await SpeechChannel.supportedLocale()
            try await recorder.start(locale: locale)
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            self.recorder = nil
            phase = .idle
            return
        }

        startedAt = recorder.startedAt ?? Date()
        systemAudioDevice = recorder.systemAudioDevice
        microphoneAvailable = recorder.microphoneAvailable
        phase = .recording
        startTicker()
    }

    /// Stops capture, enhances against the rough notes, and saves.
    @discardableResult
    func stop() async -> Meeting? {
        guard phase == .recording, let recorder else { return nil }
        phase = .finishing
        ticker?.cancel()
        ticker = nil

        let transcript = await recorder.stop()
        self.recorder = nil
        segments = transcript.segments

        // A meeting with neither a transcript nor notes is not worth a folder,
        // and silently writing an empty one would look like data loss later.
        guard !transcript.isEmpty || !roughNotes.trimmed.isEmpty else {
            errorMessage =
                "Nothing was captured. Check microphone and audio permissions, "
                + "or run `oats debug-audio` to see whether audio is reaching Oats."
            phase = .idle
            return nil
        }

        var meeting = Meeting(
            title: resolvedTitle,
            startedAt: startedAt,
            endedAt: Date(),
            roughNotes: roughNotes,
            transcript: transcript,
            templateID: templateID)

        // Never skip this silently. A meeting that comes back as "transcript
        // only" with no explanation looks like the app quietly did half its job,
        // and the reason is exactly what the user needs to fix it.
        let spokenWords = NoteEnhancer.spokenWordCount(transcript)
        switch NoteEnhancer.availability {
        case .available where transcript.isEmpty:
            break
        case _ where spokenWords < NoteEnhancer.minimumTranscriptWords:
            // Deliberate refusal rather than a failure: writing notes from this
            // little means inventing what the meeting concluded.
            errorMessage =
                "Only \(spokenWords) \(spokenWords == 1 ? "word was" : "words were") "
                + "transcribed — too little to write up without inventing the rest.\n\n"
                + "Your transcript and notes are saved."
        case .available:
            phase = .enhancing
            do {
                meeting.enhancedNotes = try await NoteEnhancer().enhance(
                    roughNotes: roughNotes,
                    transcript: transcript,
                    template: .named(templateID),
                    meetingTitle: meeting.title)
            } catch {
                // The transcript and the user's own notes are the irreplaceable
                // part; a failed polish must never cost them.
                errorMessage = "Could not write up the notes: \(error.localizedDescription)\n\nYour transcript and notes are saved."
            }
        case .unavailable(let reason):
            errorMessage = "The on-device writing model is unavailable (\(reason)).\n\nYour transcript and notes are saved."
        }

        do {
            _ = try store.save(meeting)
            lastSaved = meeting
        } catch {
            errorMessage = "Could not save the meeting: \(error.localizedDescription)"
        }

        phase = .idle
        roughNotes = ""
        title = ""
        return meeting
    }

    func dismissError() { errorMessage = nil }

    private var resolvedTitle: String {
        let trimmed = title.trimmed
        if !trimmed.isEmpty { return trimmed }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        return "Meeting \(formatter.string(from: startedAt))"
    }

    private func refreshSegments() {
        guard let recorder else { return }
        segments = recorder.currentTranscript().segments
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await MainActor.run {
                    guard self.phase == .recording else { return }
                    self.elapsed = Date().timeIntervalSince(self.startedAt)
                }
            }
        }
    }
}

extension TimeInterval {
    /// mm:ss, or h:mm:ss once a meeting runs past an hour.
    var clockString: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
