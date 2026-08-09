import Observation
import OatsKit
import SwiftUI

/// Saved meetings, read straight off disk.
///
/// There is no database and no index: `MeetingStore` reads the same Markdown and
/// JSON folders a user can open in Finder or Obsidian. Re-reading on demand is
/// what keeps "your data stays readable without us" true rather than aspirational
/// — the app is just another reader of those files.
@MainActor
@Observable
final class MeetingLibrary {
    private(set) var meetings: [Meeting] = []
    private(set) var loadError: String?
    let store: MeetingStore

    init(store: MeetingStore = MeetingStore()) {
        self.store = store
    }

    func reload() {
        do {
            meetings = try store.list()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct LibrarySidebar: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(MeetingSession.self) private var session
    @Binding var selection: Meeting.ID?

    var body: some View {
        List(selection: $selection) {
            if session.isBusy {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text(session.isRecording ? "In progress" : session.statusText)
                            .lineLimit(1)
                    }
                    .font(.callout)
                }
            }

            Section("Meetings") {
                ForEach(library.meetings) { meeting in
                    MeetingRow(meeting: meeting).tag(meeting.id)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if library.meetings.isEmpty && !session.isBusy {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "tray",
                    description: Text("Recorded meetings are saved to\n\(library.store.baseDirectory.path)"))
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt, format: .dateTime.day().month().hour().minute())
                if meeting.duration >= 60 {
                    Text("· \(Int(meeting.duration / 60)) min")
                }
                if meeting.enhancedNotes == nil {
                    Text("· transcript only")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A saved meeting: the polished notes, with the raw material behind a picker.
struct MeetingDetailView: View {
    let meeting: Meeting
    @Environment(MeetingLibrary.self) private var library
    /// Resolved against `availableTabs` before use — a meeting that was never
    /// enhanced has no Notes tab, and defaulting to it stranded the reader on
    /// "These notes were not enhanced." instead of the transcript they do have.
    @State private var tab: Tab?

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case myNotes = "My notes"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.title2.weight(.semibold))
                    Text(meeting.startedAt, format: .dateTime.weekday(.wide).day().month().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: folder.path)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help(folder.path)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if availableTabs.count > 1 {
                Picker("", selection: Binding(get: { selectedTab }, set: { tab = $0 })) {
                    ForEach(availableTabs) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            Divider()

            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Selecting a different meeting must not carry a tab that meeting lacks.
        .onChange(of: meeting.id) { _, _ in tab = nil }
    }

    /// The chosen tab if it still exists for this meeting, else the first one
    /// that does.
    private var selectedTab: Tab {
        if let tab, availableTabs.contains(tab) { return tab }
        return availableTabs.first ?? .transcript
    }

    private var availableTabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .notes: return meeting.enhancedNotes != nil
            case .myNotes: return !meeting.roughNotes.trimmed.isEmpty
            case .transcript: return !meeting.transcript.isEmpty
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .notes:
            if let notes = meeting.enhancedNotes {
                NotesText(markdown: notes)
            } else {
                Text("These notes were not enhanced.").foregroundStyle(.secondary)
            }
        case .myNotes:
            Text(meeting.roughNotes)
                .font(.system(size: 14))
                .textSelection(.enabled)
        case .transcript:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(meeting.transcript.merged()) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(segment.speaker.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(segment.speaker == .me ? Color.accentColor : .secondary)
                            Text(segment.start.clockString)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text(segment.text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var folder: URL {
        library.store.baseDirectory.appendingPathComponent(meeting.folderName)
    }
}
