import Foundation

public struct Meeting: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// What the user typed during the meeting — the outline the enhancement
    /// pass must preserve.
    public var roughNotes: String
    public var transcript: Transcript
    public var enhancedNotes: String?
    public var templateID: String

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        roughNotes: String = "",
        transcript: Transcript = Transcript(),
        enhancedNotes: String? = nil,
        templateID: String = NoteTemplate.general.id
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.roughNotes = roughNotes
        self.transcript = transcript
        self.enhancedNotes = enhancedNotes
        self.templateID = templateID
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public var template: NoteTemplate { .named(templateID) }

    /// Filesystem-safe folder name that still sorts chronologically and stays
    /// readable when browsed outside the app.
    public var folderName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug =
            title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeSlug = slug.isEmpty ? "meeting" : String(slug.prefix(48))
        return "\(formatter.string(from: startedAt))-\(safeSlug)"
    }
}
