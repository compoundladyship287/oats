# Oats — session handoff

Written 2026-08-09. Read this first when resuming; it is the full state of the
project, including the one thing that is broken right now.

## What Oats is

A local-first, open-source alternative to Granola: bot-free AI meeting notes for
macOS where **nothing leaves the machine**. Its signature move is Granola's —
you type rough fragments during the meeting, and afterwards a model merges your
notes (the outline) with the transcript (the evidence) into polished notes that
keep *your* structure. It is not a transcript summarizer.

### Decisions locked with the user

| Decision | Choice |
|---|---|
| Platform | macOS first (Apple Silicon), architected so a port is possible later |
| AI locality | **Strictly local.** No network calls for AI, ever |
| Goal | Real OSS community project — contributors, docs, CI, longevity |
| Shell | **Native SwiftUI** (changed from the original Tauri plan — see below) |
| Name | Oats ("locally sourced meeting notes") |

The plan originally specified Tauri v2 + Rust. That was reversed *after* the
spikes proved every core capability on macOS 26 is native Swift with zero
dependencies (Core Audio taps, SpeechAnalyzer, Foundation Models, EventKit), so
a Rust core would have been an FFI shim around Swift and nothing else. The user
approved the switch. Full reasoning in `docs/m0-findings.md`.

## Dev environment

MacBook Air, Apple M5, 16 GB, **macOS 26.6**, Swift 6.3.3, Xcode installed.
Rust was installed via rustup during this session but is **no longer needed**
after the SwiftUI decision. **No code-signing identity exists** on this machine
(`security find-identity -v -p codesigning` → 0 valid), which matters for
distribution and possibly for TCC behaviour in a packaged `.app`.

## Repository layout

```
.
├── HANDOFF.md              ← this file
├── docs/
│   ├── m0-findings.md      ← measured results + Core Audio gotchas. Read this.
│   └── plan.md             ← the approved plan (copied from ~/.claude/plans)
├── OatsKit/                ← THE REAL PROJECT
│   ├── Package.swift       macOS 26+, zero dependencies
│   ├── Sources/OatsKit/
│   │   ├── Capture/        SystemAudioTap, MicrophoneCapture, CoreAudioSupport
│   │   ├── Transcribe/     SpeechChannel (live ASR), Transcript (+ echo removal)
│   │   ├── Enhance/        NoteEnhancer, NoteTemplate
│   │   ├── Meeting/        Meeting, MeetingStore (Markdown + JSON on disk)
│   │   └── MeetingRecorder.swift   orchestrates both channels
│   ├── Sources/oats/       CLI: record / list / templates / doctor
│   └── Tests/OatsKitTests/ 16 tests, all passing
└── spike/                  ← throwaway proof-of-concept, superseded by OatsKit
    └── AudioCaptureSpike/  AudioCaptureSpike, TranscribeSpike, EnhanceSpike
```

## What is proven to work

All measured on this machine, not assumed:

- **System audio capture** via Core Audio process tap — 1183 callbacks, **0.00%
  frame loss**, no virtual driver, no Screen Recording permission.
- **Mic capture** as a separate stream (this is what gives "Me / Them" labelling
  with no diarization model).
- **On-device transcription** via Apple SpeechAnalyzer — ~44× realtime,
  effectively word-perfect on clean speech.
- **On-device note enhancement** via Foundation Models — 4.5 s, correctly kept
  the user's headings and pulled real specifics out of the transcript.
- **Full CLI round trip** — `oats record` captured a simulated meeting,
  transcribed both channels live, enhanced against rough notes, and saved
  Markdown + JSON. Output is in `/tmp/oats-meetings/`.
- `oats doctor` reports all four subsystems green.
- `swift test` → **16/16 passing**.

## ⚠️ Where it broke — start here

The first successful live run exposed two real bugs. Both fixes are **written
and compiling but NOT yet verified end to end**, because the session was paused
mid-verification.

1. **Mic re-hears the speakers.** Every remote utterance was transcribed twice —
   once correctly as "Them", once as "Me". Fixed two ways: enabled the OS
   voice-processing unit (`setVoiceProcessingEnabled(true)`) for real echo
   cancellation, plus `Transcript.withoutEcho()` as a dedup safety net.
2. **The two channels had different time origins** ("Me 00:05" and "Them 00:00"
   were the same moment). Fixed by stamping each buffer with an explicit
   `bufferStartTime` anchored to a shared meeting origin.

**A first attempt at fix 2 made things worse and is the reason to be careful
here.** Stamping buffers with the wall clock at ingest time caused the analyzer
to emit *nothing at all* and then hang forever in
`finalizeAndFinishThroughEndOfInput()`. The current code instead anchors once to
the shared origin and advances by real buffer durations (monotonic, exact), and
`SpeechChannel.finish()` is now bounded by a 20 s timeout so a wedged analyzer
can never cost the whole meeting.

### The exact next command to run

```bash
cd OatsKit && swift build
( sleep 3; say -r 178 "We know it is step three, the workspace invite screen. About forty percent bail there." ) &
timeout 140 ./.build/debug/oats record --title "Echo test" --minutes 0.28 --dir /tmp/oats-meetings
```

Success looks like: live segments appear during recording, each remote sentence
appears **once** and is labelled **Them**, timestamps for both speakers sit on
one timeline, and the process exits without hanging at "Finishing
transcription…".

If it hangs again at that line, the `bufferStartTime` values are still upsetting
the analyzer — the fastest diagnostic is to drop back to
`AnalyzerInput(buffer:)` with no start time, confirm transcription returns, then
reintroduce timing.

## Hard-won gotchas (do not rediscover these)

- `CATapDescription` takes **process object IDs, not PIDs**. Translate with
  `kAudioHardwarePropertyTranslatePIDToProcessObject`.
- **The tap delivers interleaved stereo.** Reading it as non-interleaved
  captures every other sample at half speed, and the symptom is a garbled
  transcript that looks like a bad ASR model rather than a layout bug. This cost
  the most time in the session. Tell: median sample-to-sample delta of exactly 0.
- The aggregate device needs the real output device as **main sub-device** with
  the tap as a sub-tap. Inverting it returns `noErr` and yields silence.
- A raw IOProc is required; `AVAudioEngine` accepts the aggregate device and
  then silently ignores it.
- Every tap failure mode returns `noErr`, so **always verify with signal level
  (dBFS) and frame-continuity accounting**, never with "it didn't throw".
- `readLine()` returns nil instantly when stdin is not a TTY, which silently
  ended recordings when run from a script. The CLI now checks `isatty`.
- Redirected stdout is block-buffered; the CLI now calls `setvbuf(_IOLBF)` so
  live output survives a killed process.

## Quality notes

Apple's on-device ~3B model is a genuinely useful zero-download tier but it is
**lossy**: in testing it dropped an explicitly stated decision (revisit mobile
when week-4 retention clears 30%, currently 22%) and invented a deadline for an
action item. Its 4,096-token window also covers prompt *and* completion, so
`NoteEnhancer` chunks transcripts over ~1,500 words. A larger local model
(Qwen3-8B class via llama.cpp) should remain the quality default; this is the
no-setup option.

## Roadmap from here

1. **Verify the two fixes above.** Nothing else matters until the live loop is
   clean.
2. Build the SwiftUI app: menu-bar presence, notepad during the meeting, live
   transcript panel, meeting library. `OatsKit` already exposes everything it
   needs.
3. EventKit calendar integration — auto-detect meeting start, use event title
   and attendees as enhancement context.
4. Optional audio retention (something Granola cannot offer — lets users verify
   the transcript against a recording).
5. Packaging: Developer ID signing + notarization. Process taps effectively rule
   out App Store distribution. **Confirm the TCC prompt behaves the same from a
   signed `.app` as it did from the CLI**, which is still unverified.
6. OSS launch: README with an honest comparison table, CONTRIBUTING,
   architecture docs, CI, MIT licence, no Pro tier.

## Competitive context

Meetily (~28.5k★) stalled in June 2026 and paywalls diarization. Hyprnote
rebranded twice and is now Anarlog, with its team focused on a closed cloud
sibling. Amurex is dead; screenpipe pivoted away. Muesli is the strongest new
macOS-native entrant. The open niches Oats targets: the notepad-first enhance
flow (barely replicated anywhere), a verifiable strictly-local guarantee, kept
audio recordings, and governance that will not bait-and-switch.
