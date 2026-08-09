import AppKit
import OatsKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotesSettings()
                .tabItem { Label("Notes", systemImage: "text.alignleft") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MeetingLibrary.self) private var library

    var body: some View {
        @Bindable var settings = settings

        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Section {
                LabeledContent("Meetings are saved to") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.storageURL.path)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Choose…") { chooseFolder() }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(
                                    nil, inFileViewerRootedAtPath: settings.storageURL.path)
                            }
                            if !settings.storagePath.isEmpty {
                                Button("Use Default") {
                                    settings.resetStorageLocation()
                                    library.reload()
                                }
                            }
                        }
                    }
                }
            } footer: {
                // Worth saying plainly: this is the whole "no lock-in" claim, and
                // it is the reason moving the folder is safe.
                Text(
                    "Meetings are plain Markdown and JSON, one folder each. "
                        + "Existing meetings are not moved when you change this.")
                // Without fixedSize the footer lays out at its natural width and
                // spills past the section, leaving fragments floating beside it.
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        // Every tab is laid out, not just the visible one, so an unconstrained
        // width lets the hidden tabs' text paint fragments over the window.
        .frame(width: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.storageURL
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.storagePath = url.path
        library.reload()
    }
}

private struct NotesSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Picker("Default template", selection: $settings.defaultTemplateID) {
                ForEach(NoteTemplate.builtIns) { Text($0.name).tag($0.id) }
            }

            Toggle("Show the live transcript while recording", isOn: $settings.showTranscriptWhileRecording)

            Section {
                LabeledContent("Writing model") {
                    Text(NoteEnhancer().model.name).foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    switch NoteEnhancer.availability {
                    case .available:
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            } footer: {
                Text(
                    "Notes are written on this Mac by Apple's on-device model. "
                        + "It needs Apple Intelligence enabled; without it you still "
                        + "get transcripts.")
                // Without fixedSize the footer lays out at its natural width and
                // spills past the section, leaving fragments floating beside it.
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        // Every tab is laid out, not just the visible one, so an unconstrained
        // width lets the hidden tabs' text paint fragments over the window.
        .frame(width: 520)
    }
}

private struct AboutSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 72, height: 72)
            }
            Text("Oats").font(.title2.weight(.semibold))
            Text("Version \(settings.appVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Locally sourced meeting notes.\nNothing leaves your Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Link("github.com/yuvrajadhikari/oats", destination: URL(string: "https://github.com/yuvrajadhikari/oats")!)
                .font(.callout)
            Text("MIT licensed").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}
