import OatsKit
import SwiftUI

@main
struct OatsApp: App {
    @State private var settings: AppSettings
    @State private var session: MeetingSession
    @State private var library: MeetingLibrary

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _session = State(initialValue: MeetingSession(settings: settings))
        _library = State(initialValue: MeetingLibrary(settings: settings))
    }

    var body: some Scene {
        Window("Oats", id: "main") {
            RootView()
                .environment(settings)
                .environment(session)
                .environment(library)
                .frame(minWidth: 860, minHeight: 540)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
        .defaultSize(width: 1040, height: 660)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Meeting…") { NotificationCenter.default.post(name: .newMeeting, object: nil) }
                    .keyboardShortcut("n")
                    .disabled(session.isBusy)

                Button(session.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await toggleRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session.phase == .starting || session.phase == .finishing
                    || session.phase == .enhancing)

                Button(session.isPaused ? "Resume Recording" : "Pause Recording") {
                    session.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!session.isRecording)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(library)
                .preferredColorScheme(settings.appearance.colorScheme)
        }

        // The menu bar is the point of an app like this: the meeting is happening
        // in another window, and starting a recording should never require
        // hunting for ours.
        MenuBarExtra("Oats", systemImage: menuBarSymbol) {
            MenuBarContent(toggleRecording: toggleRecording)
                .environment(session)
        }
    }

    private var menuBarSymbol: String {
        if session.isPaused { return "pause.circle.fill" }
        return session.isCapturing ? "record.circle.fill" : "circle.dotted"
    }

    private func toggleRecording() async {
        if session.isRecording {
            await session.stop()
            library.reload()
        } else {
            await session.start()
        }
    }
}

extension Notification.Name {
    static let newMeeting = Notification.Name("app.oats.newMeeting")
}

private struct MenuBarContent: View {
    @Environment(MeetingSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    let toggleRecording: () async -> Void

    var body: some View {
        if session.isRecording {
            Text(session.isPaused ? "Paused — \(session.elapsed.clockString)"
                : "Recording — \(session.elapsed.clockString)")
        } else if session.isBusy {
            Text(session.statusText)
        }

        Button(session.isRecording ? "Stop Recording" : "Start Recording") {
            Task { await toggleRecording() }
        }
        .disabled(session.isBusy && !session.isRecording)

        if session.isRecording {
            Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
        }

        Button("Open Oats") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Divider()
        Button("Quit Oats") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Library on the left, live meeting or a saved one on the right.
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    @State private var selection: Meeting.ID?
    @State private var showingNewMeeting = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if session.isBusy {
                RecordingView()
            } else if let meeting = library.meetings.first(where: { $0.id == selection }) {
                MeetingDetailView(meeting: meeting)
            } else {
                EmptyStateView { showingNewMeeting = true }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if session.isRecording {
                    Button {
                        session.togglePause()
                    } label: {
                        Label(
                            session.isPaused ? "Resume" : "Pause",
                            systemImage: session.isPaused ? "play.fill" : "pause.fill")
                    }
                    .help(session.isPaused ? "Resume recording" : "Pause recording")
                }
                RecordButton { showingNewMeeting = true }
            }
        }
        .sheet(isPresented: $showingNewMeeting) {
            NewMeetingSheet()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { session.errorMessage != nil || library.loadError != nil },
                set: { if !$0 { session.dismissError(); library.loadError = nil } })
        ) {
            Button("OK") { session.dismissError(); library.loadError = nil }
        } message: {
            Text(session.errorMessage ?? library.loadError ?? "")
        }
        .task { library.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .newMeeting)) { _ in
            guard !session.isBusy else { return }
            showingNewMeeting = true
        }
        .onChange(of: session.lastSaved) { _, saved in
            guard let saved else { return }
            library.reload()
            selection = saved.id
        }
    }
}

struct RecordButton: View {
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    let newMeeting: () -> Void

    var body: some View {
        Button {
            if session.isRecording {
                Task {
                    await session.stop()
                    library.reload()
                }
            } else {
                newMeeting()
            }
        } label: {
            Label(
                session.isRecording ? "Stop" : "Record",
                systemImage: session.isRecording ? "stop.fill" : "record.circle")
        }
        .disabled(session.isBusy && !session.isRecording)
        .help(session.isRecording ? "Stop and write up the meeting" : "Start a new meeting")
    }
}

/// Asks for a name before recording starts.
///
/// Naming afterwards is possible too, but a meeting you have to rename later is
/// a meeting saved as "Meeting Sunday 12:48", and a library full of those is
/// unnavigable. Everything here is optional — Return starts recording.
private struct NewMeetingSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var templateID = ""
    @State private var folder: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Meeting").font(.headline)

            Form {
                TextField("Title", text: $title, prompt: Text("Optional"))
                    .focused($titleFocused)
                    .onSubmit(start)

                Picker("Template", selection: $templateID) {
                    ForEach(NoteTemplate.builtIns) { Text($0.name).tag($0.id) }
                }

                Picker("Folder", selection: $folder) {
                    Text("Meetings").tag(String?.none)
                    ForEach(library.allFolders, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Recording", action: start)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            templateID = settings.defaultTemplateID
            titleFocused = true
        }
    }

    private func start() {
        session.title = title
        session.templateID = templateID.isEmpty ? settings.defaultTemplateID : templateID
        session.folder = folder
        dismiss()
        Task { await session.start() }
    }
}

struct EmptyStateView: View {
    let newMeeting: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No meeting selected")
                .font(.title3)
            Text("Press Record when your call starts, then type rough notes.\nOats keeps your structure and fills in the specifics.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Meeting…", action: newMeeting)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
