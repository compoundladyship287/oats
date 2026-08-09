# Oats

[![CI](https://github.com/yuvrajadhikari/oats/actions/workflows/ci.yml/badge.svg)](https://github.com/yuvrajadhikari/oats/actions/workflows/ci.yml)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B%20Apple%20Silicon-black.svg)](#requirements)

Locally sourced meeting notes.

Oats is an open-source, local-first alternative to Granola for macOS. It listens
to your meetings without joining them, transcribes both sides on-device, and
turns the rough notes you typed during the call into polished notes that keep
your own structure.

**Nothing leaves your Mac.** No transcription service, no cloud model, no
account. You can verify that with Little Snitch.

> Status: early but usable. The capture → transcribe → enhance pipeline is
> verified end to end, and the SwiftUI app runs the whole loop: record from the
> menu bar, type into the notepad, watch the live transcript, get written-up
> notes on stop. Rough edges remain — see [HANDOFF.md](HANDOFF.md).

## Why

Granola is a genuinely good product, but only its audio capture is local: your
meeting audio streams to third-party transcription services, transcripts live on
someone else's servers, and note enhancement runs on frontier cloud models. It
trains on customer data unless you opt out, the free tier stops after ~25
meetings, and in April 2026 it encrypted its local cache, breaking the community
export tools people relied on.

Oats keeps the part that makes Granola worth using — the notepad-first enhance
flow — and removes the cloud entirely.

## How it works

| Concern | Mechanism |
|---|---|
| Hearing the far end | Core Audio process tap — reads the system's own output, so no bot joins and every meeting app works |
| Hearing you | Separate microphone stream. The OS echo canceller cannot be used — it stops the process tap dead — so speaker bleed is removed from the transcript afterwards instead |
| Who said what | The two streams *are* the speaker labels: mic = you, tap = them. No diarization model |
| Transcription | Apple `SpeechAnalyzer`, on-device, ~44× realtime, with `SpeechDetector` gating the mic so room noise is not transcribed into invented sentences |
| Enhancement | Apple Foundation Models, on-device |
| Storage | Plain Markdown + JSON in `~/Documents/Oats`. Greppable, syncable, Obsidian-friendly, no lock-in |

## Requirements

| | |
|---|---|
| **macOS 26 or newer, Apple Silicon** | Not negotiable. `SpeechAnalyzer` and Foundation Models are what make the local promise possible and do not exist earlier |
| **Apple Intelligence enabled** | Otherwise transcription still works but note enhancement reports itself unavailable, and you get transcripts only |
| **Xcode or the Command Line Tools** | Only for building — see below, there is no prebuilt download yet |
| Microphone and system-audio permission | Prompted on first run |

Two things use the network, both at setup and neither for AI: Apple's speech
models install themselves on first use if they are not already present, and
`git clone` is a download. Inference never leaves the machine.

## Install

With Homebrew:

```bash
brew install yuvrajadhikari/oats/oats
```

Or without:

```bash
curl -fsSL https://raw.githubusercontent.com/yuvrajadhikari/oats/main/install.sh | bash
```

Either way, run `oats doctor` to check your setup, then open the app. Homebrew
puts it in the prefix and prints how to link it into `/Applications`; the
script installs it there directly.

Update with `brew upgrade oats`, or by re-running the script. Remove with
`brew uninstall oats`, or `install.sh --uninstall`. Your meetings are left
alone either way — they are plain files in `~/Documents/Oats`.

<details>
<summary>Piping a script to bash, for a privacy tool?</summary>

Fair objection, and Homebrew is the better option if you have it.
[`install.sh`](install.sh) is short and meant to be read — it checks your macOS
version, clones this repo, runs `swift build`, and copies the result into
`/Applications`. Nothing else. If you would rather look first:

```bash
git clone https://github.com/yuvrajadhikari/oats.git && cd oats
less install.sh && ./install.sh
```

</details>

**Why build from source rather than download an app?** Because a downloaded app
would need an Apple Developer ID to be signed and notarized, and without one
macOS refuses to open it — the workaround being to strip the quarantine flag off
a binary that records your meetings, which is precisely the wrong habit to
teach. Something you compiled yourself never gets that flag. A notarized DMG and
a Homebrew cask are the plan once there is a Developer ID.

The first build takes a minute or two. After that, press ⌘N to name a meeting
and start, type rough notes while you talk, and press ⇧⌘R to stop. Oats writes
the notes to `~/Documents/Oats`.

## What it does

- **A first run that sets you up** — what Oats is, the permissions it needs and
  why, and where notes go. The permissions are unusual and failure is silent, so
  asking up front beats a transcript that mysteriously has only one voice in it.
- **A home screen** that tells you the machine is actually ready to record, and
  says which permission is missing when it is not.

- **Record from the menu bar** — ⌘N to start a named meeting, ⇧⌘R to stop,
  ⇧⌘P to pause. Pausing keeps the transcript continuous rather than leaving a
  gap the length of your coffee break.
- **Floating controls while you record** — a small pill above every app and
  every Space with the elapsed time, pause, and stop. It appears when recording
  starts, disappears when it ends, and clicking it does not pull focus out of
  the call you are in. Drag it anywhere; it stays put.
- **Resume a past meeting** — pick it and hit Resume. The new audio is appended
  to the same meeting and the notes are rewritten over the whole thing, instead
  of a call that restarted after a break ending up as two unrelated entries.
- **A notepad and a live transcript** side by side while the meeting runs.
- **Written-up notes on stop**, keeping your headings and filling in the
  specifics from what was actually said.
- **A library with folders** — group meetings, rename them, move them, or drag
  them around in Finder and Oats follows.
- **Copy** the notes or the transcript to the clipboard in one click.
- **Light and dark**, following the system or pinned in Settings (⌘,), where you
  can also move the storage folder and pick a default template.

<details>
<summary>Building by hand instead</summary>

```bash
git clone https://github.com/yuvrajadhikari/oats.git && cd oats
cd OatsApp && ./scripts/bundle.sh release --run
```

</details>

Or the CLI, which runs the same engine and is quicker to poke at:

```bash
cd OatsKit
swift build
./.build/debug/oats doctor          # check permissions and models
./.build/debug/oats record --title "Standup" --notes ~/notes.md
```

Keep your notes file open in another window and jot into it during the call.
Press Return to stop. Oats merges your notes with the transcript and writes the
result to `~/Documents/Oats`.

```
oats record [--title T] [--template ID] [--notes FILE] [--minutes N]
oats list · oats templates · oats doctor · oats debug-audio
```

Works on speakers or headphones. On speakers your microphone also hears the far
end, and Oats drops those duplicates from the transcript so each remote sentence
is attributed once — but headphones still give the cleanest result.

If a recording comes back empty, run `oats debug-audio`. Every failure mode in
the macOS audio stack here reports success, so signal levels and callback counts
are the only reliable evidence.

## Design commitments

These are the reasons to pick Oats over the alternatives, so they are not
negotiable:

- **Strictly local.** No network calls for AI. Ever.
- **No open-core.** MIT, one edition. Features do not get moved behind a Pro
  tier later.
- **Your data stays readable without us.** Plain files, never an encrypted cache.
- **Keep the audio if you want it.** Granola cannot offer this; it means you can
  check the transcript against what was actually said.

## Repository

- `OatsApp/` — the SwiftUI app. A plain SwiftPM package plus `scripts/bundle.sh`,
  which wraps the binary into `Oats.app`; no Xcode project to keep in sync.
- `OatsKit/` — the engine (capture, transcribe, enhance, storage) plus the CLI.
  Zero dependencies, deliberately usable on its own.
- `docs/m0-findings.md` — measured results and the Core Audio traps found the
  hard way. Worth reading before touching the capture code.
- `spike/` — throwaway proofs of concept, superseded by `OatsKit`.

## Contributing

Yes please — see [CONTRIBUTING.md](CONTRIBUTING.md). If you are going anywhere
near the audio code, read the "Hard-won gotchas" section of
[HANDOFF.md](HANDOFF.md) first. Every failure mode in this pipeline returns
success, so a dead capture path and a healthy one look identical unless you
check signal levels; `oats debug-audio` is the tool for that.

## Licence

MIT — see [LICENSE](LICENSE). One edition, no Pro tier, no open-core.
