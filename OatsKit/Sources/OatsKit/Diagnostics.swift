import AVFoundation
import Foundation

/// One subsystem's readiness.
public struct SystemCheck: Sendable, Identifiable, Equatable {
    public enum State: Sendable, Equatable {
        case ready
        /// Fixable by the user — a permission they can grant, a setting to turn on.
        case actionNeeded(String)
        /// Not fixable here: wrong hardware, wrong OS, model missing.
        case unavailable(String)
    }

    public let id: String
    public let name: String
    public let state: State
    /// What is true right now, shown next to the name.
    public let detail: String

    public var isReady: Bool { state == .ready }
}

/// What `oats doctor`, the onboarding flow, and the home screen all report from.
///
/// Shared rather than duplicated because the three drifting apart is how you get
/// an app that says everything is fine while the CLI says a permission is
/// missing. Every check is cheap enough to run on appearance.
@available(macOS 26.0, *)
public enum Diagnostics {
    public static func microphone() -> SystemCheck {
        let granted = MicrophoneCapture.hasAccess
        return SystemCheck(
            id: "microphone",
            name: "Microphone",
            state: granted
                ? .ready
                : .actionNeeded("Oats needs the microphone to hear your side of the call."),
            detail: granted ? "Granted" : "Not granted")
    }

    public static func speech() async -> SystemCheck {
        do {
            let locale = try await SpeechChannel.supportedLocale()
            return SystemCheck(
                id: "speech", name: "On-device transcription", state: .ready,
                detail: locale.identifier)
        } catch {
            return SystemCheck(
                id: "speech", name: "On-device transcription",
                state: .unavailable("\(error.localizedDescription)"),
                detail: "Unavailable")
        }
    }

    public static func languageModel() -> SystemCheck {
        switch NoteEnhancer.availability {
        case .available:
            return SystemCheck(
                id: "model", name: "Note writing", state: .ready,
                detail: NoteEnhancer().model.name)
        case .unavailable(let reason):
            // Deliberately not fatal, and worth saying so: transcription still
            // works without Apple Intelligence, you just get transcripts.
            return SystemCheck(
                id: "model", name: "Note writing",
                state: .actionNeeded(
                    "Turn on Apple Intelligence in System Settings to get written-up "
                        + "notes. Without it Oats still records and transcribes."),
                detail: "\(reason)")
        }
    }

    /// Building a tap is what triggers the system-audio permission prompt, so
    /// this doubles as the request.
    public static func systemAudio() -> SystemCheck {
        let tap = SystemAudioTap()
        do {
            try tap.prepare()
            let device = tap.outputDeviceName
            tap.stop()
            return SystemCheck(
                id: "systemAudio", name: "System audio", state: .ready,
                detail: device.isEmpty ? "Ready" : device)
        } catch {
            return SystemCheck(
                id: "systemAudio", name: "System audio",
                state: .actionNeeded(
                    "Oats needs to hear what your Mac is playing — that is the other "
                        + "side of the call."),
                detail: "Not available")
        }
    }

    /// In the order a user should care about them.
    public static func all() async -> [SystemCheck] {
        [microphone(), systemAudio(), await speech(), languageModel()]
    }

    /// Recording is possible without the writing model; it is not possible
    /// without something to listen to.
    public static func canRecord(_ checks: [SystemCheck]) -> Bool {
        checks.first { $0.id == "microphone" }?.isReady == true
            || checks.first { $0.id == "systemAudio" }?.isReady == true
    }
}
