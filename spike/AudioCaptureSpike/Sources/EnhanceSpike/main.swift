import Foundation
import FoundationModels

// M2 spike: the Granola move. Merge the user's rough, fragmentary meeting notes
// with the transcript into polished notes that keep the user's own structure —
// running entirely on-device via Apple's Foundation Models (macOS 26+).
//
// This is deliberately *not* "summarize the transcript". The user's notes are
// the skeleton and the transcript is the evidence; the output must follow the
// user's headings and emphasis, not the model's idea of what mattered.
//
//   swift run EnhanceSpike <transcript.txt> <rough-notes.txt>

@available(macOS 26.0, *)
func enhance(transcript: String, notes: String) async throws -> Int32 {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
        break
    case .unavailable(let reason):
        print("On-device model unavailable: \(reason)")
        print("Oats would fall back to llama.cpp + Qwen3 here.")
        return 1
    @unknown default:
        print("On-device model unavailable for an unknown reason.")
        return 1
    }

    let session = LanguageModelSession(
        instructions: """
            You turn a person's rough meeting notes into polished notes, using the \
            meeting transcript as evidence.

            Rules:
            - The user's notes are the outline. Keep their headings, their order, \
            and their emphasis. Do not reorganize into your own structure.
            - Expand each of the user's fragments using specifics from the \
            transcript: numbers, names, dates, and decisions.
            - Where the user wrote a question, answer it from the transcript if \
            the transcript answers it.
            - Never invent anything not supported by the transcript.
            - Keep it terse and factual. No preamble, no "in this meeting" framing.
            - End with an "Action items" section listing owners where stated.
            - Output Markdown.
            """
    )

    let prompt = """
        Here is the transcript of the meeting:

        <transcript>
        \(transcript)
        </transcript>

        Here are my rough notes taken during the meeting:

        <notes>
        \(notes)
        </notes>

        Rewrite my notes as polished meeting notes.
        """

    print("Oats — on-device note enhancement spike")
    print(String(repeating: "─", count: 60))
    print("transcript: \(transcript.split(separator: " ").count) words")
    print("rough notes: \(notes.split(separator: "\n").count) lines")
    print("model: Apple on-device (SystemLanguageModel.default)\n")

    let started = Date()
    let response = try await session.respond(to: prompt)
    let elapsed = Date().timeIntervalSince(started)

    print(String(repeating: "─", count: 60))
    print(response.content)
    print(String(repeating: "─", count: 60))
    print(String(format: "generated in %.1fs", elapsed))
    return 0
}

let arguments = CommandLine.arguments
guard arguments.count > 2 else {
    print("usage: EnhanceSpike <transcript.txt> <rough-notes.txt>")
    exit(2)
}
let transcript = try String(contentsOf: URL(fileURLWithPath: arguments[1]), encoding: .utf8)
let notes = try String(contentsOf: URL(fileURLWithPath: arguments[2]), encoding: .utf8)

if #available(macOS 26.0, *) {
    exit(try await enhance(transcript: transcript, notes: notes))
} else {
    print("Foundation Models needs macOS 26; the portable path uses llama.cpp + Qwen3.")
    exit(1)
}
