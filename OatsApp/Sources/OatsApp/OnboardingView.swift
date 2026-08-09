import AppKit
import OatsKit
import SwiftUI

/// First run: what Oats is, the permissions it needs, and where notes go.
///
/// It exists because the permissions are unusual and failure is silent. Oats
/// needs *system audio*, which almost nothing else asks for, and if the user
/// dismisses that prompt during a real meeting they get a transcript with only
/// their own voice in it and no explanation. Asking up front, with the reason
/// next to the button, is the difference between a tool that works and one that
/// looks broken.
struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @State private var step = 0
    @State private var checks: [SystemCheck] = []
    @State private var requesting = false

    private let lastStep = 2

    var body: some View {
        VStack(spacing: 0) {
            content
                // Each step needs its own identity. Without it the branches of
                // the switch share one, so SwiftUI cross-fades in place and the
                // previous step stays painted underneath at partial opacity.
                .id(step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 48)

            Divider()

            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PageDots(count: lastStep + 1, current: step)
                Spacer()
                primaryButton
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 640, minHeight: 560)
        .task { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcome
        case 1: permissions
        default: ready
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            OatsWordmark(size: 104, animated: true, tagline: nil)

            VStack(spacing: 10) {
                Text("Meeting notes that never leave your Mac")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(
                    "Oats listens to your meetings without joining them, transcribes "
                        + "both sides on this machine, and turns the rough notes you type "
                        + "into polished ones that keep your structure."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            }

            HStack(spacing: 26) {
                Promise(icon: "wifi.slash", title: "No cloud", detail: "No account, no uploads")
                Promise(icon: "doc.plaintext", title: "Plain files", detail: "Markdown you can keep")
                Promise(icon: "person.2.slash", title: "No bot", detail: "Nothing joins your call")
            }
            .padding(.top, 6)
            Spacer()
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text("Let Oats hear the meeting")
                    .font(.title2.weight(.semibold))
                Text(
                    "Two streams, kept separate — that is how Oats labels who said "
                        + "what without any speaker-recognition model."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(checks) { check in
                    CheckRow(check: check)
                }
            }

            if checks.contains(where: { !$0.isReady }) {
                Button {
                    Task { await request() }
                } label: {
                    if requesting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking…")
                        }
                    } else {
                        Text("Grant Access")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(requesting)

                Text(
                    "macOS will ask once for each. If you have already said no, the "
                        + "switches live in System Settings → Privacy & Security."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: 520)
    }

    private var ready: some View {
        VStack(spacing: 20) {
            Spacer()
            OatsLogo(size: 88)
            Text("You're set up")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                Step(number: 1, text: "Press **New Meeting** when your call starts.")
                Step(number: 2, text: "Type rough fragments in the notepad — they do not need to be tidy.")
                Step(number: 3, text: "Press **Stop**. Oats writes them up using what was actually said.")
            }
            .frame(maxWidth: 420, alignment: .leading)

            LabeledContent {
                Text(settings.storageURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Text("Notes are saved to").font(.caption)
            }
            .frame(maxWidth: 420)
            .padding(.top, 4)

            // Seen in testing: macOS raises a third prompt, for the Documents
            // folder, the first time Oats reads its own notes. Unannounced it
            // looks like the app is reaching somewhere it should not.
            Text(
                "macOS may ask for access to your Documents folder — that is Oats "
                    + "reading its own notes. You can change any of this later in Settings."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            Spacer()
        }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var primaryButton: some View {
        if step < lastStep {
            Button(step == 0 ? "Get Started" : "Continue") {
                withAnimation { step += 1 }
                Task { await refresh() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        } else {
            Button("Start Using Oats") {
                settings.hasCompletedOnboarding = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func refresh() async {
        checks = await Diagnostics.all()
    }

    /// Touching each subsystem is what raises its prompt; there is no API to ask
    /// for system-audio access other than trying to build the tap.
    private func request() async {
        requesting = true
        _ = await MicrophoneCapture.requestAccess()
        _ = Diagnostics.systemAudio()
        await refresh()
        requesting = false
    }
}

// MARK: - Pieces

private struct Promise: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 130)
    }
}

private struct CheckRow: View {
    let check: SystemCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.isReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(check.isReady ? Color.green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(check.name).font(.callout.weight(.medium))
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if case .actionNeeded(let why) = check.state {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .unavailable(let why) = check.state {
                    Text(why)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.quaternary, in: Circle())
            Text(.init(text)).font(.callout)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
