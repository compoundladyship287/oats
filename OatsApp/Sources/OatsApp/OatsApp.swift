import OatsKit
import SwiftUI

@main
struct OatsApp: App {
    @State private var session = MeetingSession()
    @State private var library = MeetingLibrary()

    var body: some Scene {
        Window("Oats", id: "main") {
            RootView()
                .environment(session)
                .environment(library)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1040, height: 660)
        .commands {
            CommandGroup(after: .newItem) {
                Button(session.isRecording ? "Stop Recording" : "Start Recording") {
                    Task { await toggle() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session.phase == .starting || session.phase == .finishing
                    || session.phase == .enhancing)
            }
        }

        // The menu bar is the point of an app like this: the meeting is happening
        // in another window, and starting a recording should never require
        // hunting for ours.
        MenuBarExtra("Oats", systemImage: session.isRecording ? "record.circle.fill" : "circle.dotted") {
            MenuBarContent(toggle: toggle)
                .environment(session)
        }
    }

    private func toggle() async {
        if session.isRecording {
            await session.stop()
            library.reload()
        } else {
            await session.start()
        }
    }
}

private struct MenuBarContent: View {
    @Environment(MeetingSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    let toggle: () async -> Void

    var body: some View {
        if session.isRecording {
            Text("Recording — \(session.elapsed.clockString)")
        } else if session.isBusy {
            Text(session.statusText)
        }

        Button(session.isRecording ? "Stop Recording" : "Start Recording") {
            Task { await toggle() }
        }
        .disabled(session.isBusy && !session.isRecording)

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
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingLibrary.self) private var library
    @State private var selection: Meeting.ID?

    var body: some View {
        @Bindable var session = session

        NavigationSplitView {
            LibrarySidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if session.isBusy {
                RecordingView()
            } else if let meeting = library.meetings.first(where: { $0.id == selection }) {
                MeetingDetailView(meeting: meeting)
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.dismissError() } })
        ) {
            Button("OK") { session.dismissError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .task { library.reload() }
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

    var body: some View {
        Button {
            Task {
                if session.isRecording {
                    await session.stop()
                    library.reload()
                } else {
                    await session.start()
                }
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

struct EmptyStateView: View {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
