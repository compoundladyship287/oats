import Foundation

/// Meetings on disk as plain files.
///
/// One folder per meeting containing `meeting.json` (canonical), `notes.md`, and
/// `transcript.md`. Deliberately not an opaque database: Granola encrypting its
/// local cache in 2026 broke every community export tool overnight, and the
/// whole point of Oats is that your meetings stay yours — greppable, syncable,
/// and readable in Obsidian or any editor without Oats installed.
public struct MeetingStore: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory =
            baseDirectory
            ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Oats", isDirectory: true)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @discardableResult
    public func save(_ meeting: Meeting) throws -> URL {
        let folder = baseDirectory.appendingPathComponent(meeting.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try encoder.encode(meeting)
            .write(to: folder.appendingPathComponent("meeting.json"))
        try Self.notesMarkdown(for: meeting)
            .write(
                to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try Self.transcriptMarkdown(for: meeting)
            .write(
                to: folder.appendingPathComponent("transcript.md"), atomically: true,
                encoding: .utf8)
        return folder
    }

    public func load(from folder: URL) throws -> Meeting {
        let data = try Data(contentsOf: folder.appendingPathComponent("meeting.json"))
        return try decoder.decode(Meeting.self, from: data)
    }

    /// Most recent first.
    public func list() throws -> [Meeting] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }
        let folders = try fileManager.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil)
        return
            folders
            .compactMap { try? load(from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Rendering

    static func notesMarkdown(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        var lines = [
            "---",
            "title: \(meeting.title)",
            "date: \(ISO8601DateFormatter().string(from: meeting.startedAt))",
            "duration_minutes: \(Int(meeting.duration / 60))",
            "template: \(meeting.templateID)",
            "---",
            "",
            "# \(meeting.title)",
            "",
            "*\(formatter.string(from: meeting.startedAt))*",
            "",
        ]

        if let enhanced = meeting.enhancedNotes, !enhanced.isEmpty {
            lines.append(enhanced)
        } else {
            lines.append("## Notes")
            lines.append("")
            lines.append(
                meeting.roughNotes.isEmpty ? "*No notes taken.*" : meeting.roughNotes)
        }

        if !meeting.roughNotes.isEmpty, meeting.enhancedNotes != nil {
            lines.append(contentsOf: ["", "---", "", "## My original notes", "", meeting.roughNotes])
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func transcriptMarkdown(for meeting: Meeting) -> String {
        var lines = ["# Transcript — \(meeting.title)", ""]
        for segment in meeting.transcript.merged() {
            let minutes = Int(segment.start) / 60
            let seconds = Int(segment.start) % 60
            lines.append(
                String(
                    format: "**%@** `%02d:%02d`  \n%@\n", segment.speaker.displayName, minutes,
                    seconds, segment.text))
        }
        return lines.joined(separator: "\n")
    }
}
