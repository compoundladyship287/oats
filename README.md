# Oats

Locally sourced meeting notes.

Oats is an open-source, local-first alternative to Granola for macOS. It listens
to your meetings without joining them, transcribes both sides on-device, and
turns the rough notes you typed during the call into polished notes that keep
your own structure.

**Nothing leaves your Mac.** No transcription service, no cloud model, no
account. You can verify that with Little Snitch.

> Status: early. The capture → transcribe → enhance pipeline works end to end
> from the CLI; the SwiftUI app is not built yet. See [HANDOFF.md](HANDOFF.md)
> for exactly what works and what is still broken.

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
| Hearing you | Separate microphone stream with OS echo cancellation |
| Who said what | The two streams *are* the speaker labels: mic = you, tap = them. No diarization model |
| Transcription | Apple `SpeechAnalyzer`, on-device, ~44× realtime |
| Enhancement | Apple Foundation Models, on-device |
| Storage | Plain Markdown + JSON in `~/Documents/Oats`. Greppable, syncable, Obsidian-friendly, no lock-in |

Requires macOS 26 or newer (that is where the on-device speech and language
models live) on Apple Silicon.

## Try it

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
oats list · oats templates · oats doctor
```

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

- `OatsKit/` — the engine (capture, transcribe, enhance, storage) plus the CLI.
  Zero dependencies, deliberately usable on its own.
- `docs/m0-findings.md` — measured results and the Core Audio traps found the
  hard way. Worth reading before touching the capture code.
- `spike/` — throwaway proofs of concept, superseded by `OatsKit`.

## Licence

MIT.
