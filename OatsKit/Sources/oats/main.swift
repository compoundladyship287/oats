import Foundation
import OatsKit

// The Oats command line. The SwiftUI app is the product, but a CLI that runs the
// same OatsKit engine keeps the pipeline testable without a GUI in the loop and
// makes the whole thing scriptable.

struct Arguments {
    var command: String = "help"
    var title: String?
    var template: String = "general"
    var notesPath: String?
    var minutes: Double?
    var locale: String = "en-US"
    var directory: String?

    init(_ raw: [String]) {
        var rest = Array(raw.dropFirst())
        if let first = rest.first, !first.hasPrefix("--") {
            command = first
            rest.removeFirst()
        }
        var index = 0
        while index < rest.count {
            let flag = rest[index]
            let value = index + 1 < rest.count ? rest[index + 1] : nil
            switch flag {
            case "--title": title = value; index += 1
            case "--template": template = value ?? "general"; index += 1
            case "--notes": notesPath = value; index += 1
            case "--minutes": minutes = value.flatMap(Double.init); index += 1
            case "--locale": locale = value ?? "en-US"; index += 1
            case "--dir": directory = value; index += 1
            default: break
            }
            index += 1
        }
    }
}

func printUsage() {
    print(
        """
        oats — local-first meeting notes. Nothing leaves your Mac.

        USAGE
          oats record [--title T] [--template ID] [--notes FILE] [--minutes N] [--locale L]
          oats list [--dir PATH]
          oats templates
          oats doctor

        RECORD
          Captures system audio and your microphone, transcribes both live on-device,
          then merges your rough notes with the transcript into polished notes.
          Press Return to stop, or pass --minutes to stop automatically.

          --notes FILE   Your rough notes. Keep this file open in another window and
                         jot into it during the meeting; Oats reads it when you stop.

        TEMPLATES
          \(NoteTemplate.builtIns.map(\.id).joined(separator: ", "))
        """)
}

@available(macOS 26.0, *)
func runDoctor() async {
    print("oats doctor")
    print(String(repeating: "─", count: 46))

    let micGranted = MicrophoneCapture.hasAccess
    print("microphone permission   \(micGranted ? "granted" : "not yet granted")")

    do {
        let locale = try await SpeechChannel.supportedLocale()
        print("on-device speech        available (\(locale.identifier))")
    } catch {
        print("on-device speech        UNAVAILABLE — \(error)")
    }

    switch NoteEnhancer.availability {
    case .available:
        print("on-device language model available")
    case .unavailable(let reason):
        print("on-device language model UNAVAILABLE — \(reason)")
    }

    let tap = SystemAudioTap()
    do {
        try tap.prepare()
        print("system audio tap        ready (\(tap.outputDeviceName))")
        tap.stop()
    } catch {
        print("system audio tap        FAILED — \(error)")
    }

    print(String(repeating: "─", count: 46))
    print("notes are stored in     \(MeetingStore().baseDirectory.path)")
}

@available(macOS 26.0, *)
func runRecord(_ arguments: Arguments) async throws {
    let store = MeetingStore(
        baseDirectory: arguments.directory.map { URL(fileURLWithPath: $0) })
    let title = arguments.title ?? defaultTitle()
    let locale = try await SpeechChannel.supportedLocale(preferring: arguments.locale)

    let recorder = MeetingRecorder()
    recorder.onSegment = { segment in
        let minutes = Int(segment.start) / 60
        let seconds = Int(segment.start) % 60
        let label = segment.speaker == .me ? "Me  " : "Them"
        print(String(format: "  %02d:%02d  %@  %@", minutes, seconds, label, segment.text))
    }

    print("Oats — recording \"\(title)\"")
    print("Preparing on-device models…")
    try await recorder.start(locale: locale)

    print("Capturing \(recorder.systemAudioDevice) + microphone"
        + (recorder.microphoneAvailable ? "" : " (MIC UNAVAILABLE — only their side will be heard)"))
    if let path = arguments.notesPath {
        print("Rough notes: \(path) — jot into it while you talk.")
    }
    print(arguments.minutes.map { "Stopping after \($0) minutes. " } ?? "" + "Press Return to stop.")
    print(String(repeating: "─", count: 60))

    await waitForStop(minutes: arguments.minutes)

    print(String(repeating: "─", count: 60))
    print("Finishing transcription…")
    let transcript = await recorder.stop()

    if recorder.frameLossFraction > 0.001 {
        print(String(format: "warning: dropped %.2f%% of system audio frames",
                     recorder.frameLossFraction * 100))
    }
    guard !transcript.isEmpty else {
        print("Nothing was transcribed. Run `oats doctor` to check permissions.")
        return
    }

    let roughNotes = arguments.notesPath
        .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""

    var meeting = Meeting(
        title: title,
        startedAt: recorder.startedAt ?? Date(),
        endedAt: Date(),
        roughNotes: roughNotes,
        transcript: transcript,
        templateID: arguments.template)

    print("Enhancing \(transcript.segments.count) segments with your notes…")
    switch NoteEnhancer.availability {
    case .available:
        do {
            meeting.enhancedNotes = try await NoteEnhancer().enhance(
                roughNotes: roughNotes,
                transcript: transcript,
                template: .named(arguments.template),
                meetingTitle: title)
        } catch {
            print("Enhancement failed (\(error)); saving the raw transcript and your notes.")
        }
    case .unavailable(let reason):
        print("On-device model unavailable (\(reason)); saving transcript and notes only.")
    }

    let folder = try store.save(meeting)
    print(String(repeating: "─", count: 60))
    if let enhanced = meeting.enhancedNotes { print(enhanced) }
    print(String(repeating: "─", count: 60))
    print("Saved to \(folder.path)")
}

/// Returns when the user presses Return, the time limit elapses, or the process
/// is interrupted.
///
/// Only watches stdin when it is a terminal. When Oats is run from a script or
/// with stdin redirected, `readLine()` returns nil immediately at EOF, which
/// would end the meeting the instant it started.
func waitForStop(minutes: Double?) async {
    let interactive = isatty(STDIN_FILENO) == 1

    await withTaskGroup(of: Void.self) { group in
        if interactive {
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        _ = readLine()
                        continuation.resume()
                    }
                }
            }
        }
        if let minutes {
            group.addTask {
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
        // Without a stop signal there is nothing to wait for, and returning
        // immediately would silently record nothing.
        if !interactive && minutes == nil {
            group.addTask {
                print("stdin is not a terminal; recording until interrupted (Ctrl-C).")
                try? await Task.sleep(for: .seconds(60 * 60 * 8))
            }
        }
        await group.next()
        group.cancelAll()
    }
}

func defaultTitle() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE HH:mm"
    return "Meeting \(formatter.string(from: Date()))"
}

@available(macOS 26.0, *)
func runList(_ arguments: Arguments) throws {
    let store = MeetingStore(baseDirectory: arguments.directory.map { URL(fileURLWithPath: $0) })
    let meetings = try store.list()
    guard !meetings.isEmpty else {
        print("No meetings yet in \(store.baseDirectory.path)")
        return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    for meeting in meetings {
        print(
            String(
                format: "%@  %-40@  %3d min  %d segments",
                formatter.string(from: meeting.startedAt),
                meeting.title as NSString,
                Int(meeting.duration / 60),
                meeting.transcript.segments.count))
    }
}

// MARK: - Entry point

// Line-buffer stdout so live transcript lines appear immediately when the output
// is piped or redirected, not only when the process exits.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Arguments(CommandLine.arguments)

guard #available(macOS 26.0, *) else {
    print("Oats needs macOS 26 or newer for on-device speech and language models.")
    exit(1)
}

do {
    switch arguments.command {
    case "record": try await runRecord(arguments)
    case "list": try runList(arguments)
    case "doctor": await runDoctor()
    case "templates":
        for template in NoteTemplate.builtIns {
            print("\(template.id.padding(toLength: 16, withPad: " ", startingAt: 0))\(template.name)")
            print("  sections: \(template.sections.joined(separator: ", "))")
        }
    default: printUsage()
    }
} catch {
    print("error: \(error)")
    exit(1)
}
