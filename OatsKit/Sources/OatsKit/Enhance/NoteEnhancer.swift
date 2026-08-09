import Foundation
import FoundationModels

/// Turns rough notes plus a transcript into polished notes, on-device.
///
/// This is the move Oats exists for, and it is not summarization: the user's
/// notes are the outline and the transcript is the evidence. Output follows the
/// user's headings, order, and emphasis — a summarizer that reorganizes the
/// meeting into its own idea of what mattered has failed at this job.
@available(macOS 26.0, *)
public struct NoteEnhancer: Sendable {

    /// Apple's on-device model has a 4,096-token window covering prompt *and*
    /// completion, so a long meeting cannot be enhanced in one pass. Past this
    /// many words we condense the transcript in chunks first.
    private static let singlePassWordLimit = 1_500
    private static let chunkWordLimit = 1_200

    public enum Availability: Sendable, Equatable {
        case available
        case unavailable(String)
    }

    public init() {}

    public static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable("\(reason)")
        @unknown default:
            return .unavailable("unknown")
        }
    }

    public func enhance(
        roughNotes: String,
        transcript: Transcript,
        template: NoteTemplate = .general,
        meetingTitle: String? = nil
    ) async throws -> String {
        let text = transcript.formatted()
        guard !text.isEmpty else {
            throw CaptureError.message("Nothing was transcribed, so there is nothing to enhance")
        }

        let source =
            wordCount(text) > Self.singlePassWordLimit
            ? try await condense(text)
            : text

        let session = LanguageModelSession(instructions: instructions(for: template))
        let response = try await session.respond(
            to: prompt(
                transcript: source,
                roughNotes: roughNotes,
                template: template,
                meetingTitle: meetingTitle))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompting

    private func instructions(for template: NoteTemplate) -> String {
        """
        You turn a person's rough meeting notes into polished notes, using the \
        meeting transcript as evidence.

        Rules:
        - The user's notes are the outline. Keep their headings, their order, and \
        their emphasis. Never reorganize into your own structure.
        - Expand each fragment with specifics from the transcript: numbers, names, \
        dates, owners, and decisions. Prefer the speakers' own words.
        - Where the user wrote a question, answer it if the transcript answers it.
        - Record every decision explicitly stated, including any condition or \
        threshold attached to it.
        - Never invent anything the transcript does not support. If the user noted \
        something the transcript never covers, keep their line unchanged.
        - Be terse and factual. No preamble and no "in this meeting" framing.
        - Output Markdown, starting directly with the first heading.

        For a meeting of this type: \(template.guidance)
        If the user's notes imply no structure, fall back to these sections: \
        \(template.sections.joined(separator: ", ")).
        Always end with an "Action items" section listing owners where stated.
        """
    }

    private func prompt(
        transcript: String, roughNotes: String, template: NoteTemplate, meetingTitle: String?
    ) -> String {
        let trimmedNotes = roughNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesBlock =
            trimmedNotes.isEmpty
            ? "(The user took no notes. Use the template sections and keep it brief.)"
            : trimmedNotes

        return """
            \(meetingTitle.map { "Meeting: \($0)\n" } ?? "")Transcript:

            <transcript>
            \(transcript)
            </transcript>

            My rough notes from during the meeting:

            <notes>
            \(notesBlock)
            </notes>

            Rewrite my notes as polished meeting notes.
            """
    }

    // MARK: - Long meetings

    /// Condenses a long transcript chunk by chunk so the enhancement pass fits
    /// in the model's context. Chunks split on speaker turns rather than raw
    /// word counts, so an utterance is never cut in half.
    private func condense(_ transcript: String) async throws -> String {
        let chunks = Self.chunk(transcript, maxWords: Self.chunkWordLimit)
        var condensed: [String] = []
        condensed.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let session = LanguageModelSession(
                instructions: """
                    You compress a section of a meeting transcript while losing no \
                    facts. Keep every decision, number, name, owner, date, and \
                    commitment, and keep the speaker labels. Drop only filler and \
                    small talk. Output plain lines, no preamble.
                    """)
            let response = try await session.respond(
                to: """
                    Section \(index + 1) of \(chunks.count):

                    \(chunk)
                    """)
            condensed.append(response.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return condensed.joined(separator: "\n")
    }

    static func chunk(_ transcript: String, maxWords: Int) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0

        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = line.split(separator: " ").count
            if currentWords + words > maxWords, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentWords = 0
            }
            current.append(String(line))
            currentWords += words
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
}
