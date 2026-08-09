# Oats — session handoff

Updated 2026-08-09 (second session). Read this first when resuming; it is the
full state of the project.

**The live loop is now clean and verified end to end.** The two bugs the last
session left open are fixed, but not by the fixes it had written — one of those
fixes was itself the cause of a worse failure. See "What the last session got
wrong" below before touching capture.

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
├── OatsApp/                ← THE SWIFTUI APP (SwiftPM + bundle.sh)
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
│   ├── Sources/oats/       CLI: record / list / templates / doctor / debug-audio
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
- **Echo dedup on a real speaker recording** — the mic's duplicate of each
  remote sentence is removed, leaving one correctly attributed "Them" segment.
- **Clean shutdown** — no hang at "Finishing transcription…".
- `oats doctor` reports all four subsystems green.
- `swift test` → **16/16 passing**.

`oats doctor` being green is necessary but **not** sufficient: it reported all
four subsystems healthy throughout the session in which nothing was transcribed
at all. Use `oats debug-audio` to confirm audio is actually flowing.

## What the last session got wrong

Resuming, the prescribed verification command produced **zero transcription** and
then hung for the full 140 s. Diagnosis found three separate faults; only the
last one was on the previous session's list.

### 1. Voice processing and the process tap are mutually exclusive

This is the important one, and it is the reverse of what the last session
believed. `setVoiceProcessingEnabled(true)` — written as the echo fix — is what
broke the pipeline. On macOS 26.6 it costs **both** channels:

- **The tap dies.** `AudioDeviceStart` still returns `noErr` and the IOProc then
  never fires once. Measured in the same run, back to back:

  | tap | voice processing | mic format | tap callbacks |
  |---|---|---|---|
  | yes | **off** | 48 kHz / 1 ch | **285** |
  | yes | **on** | 48 kHz / 7 ch | **0** |

- **The mic goes silent downstream.** VPIO switches the input node to a
  7-channel format. Channel 0 still carries real audio, but `AVAudioConverter`
  renders that layout into the analyzer's mono format as pure digital silence
  (-inf dBFS), so the "Me" channel transcribes nothing either.

Echo cancellation is therefore **off** and must stay off while the tap runs.
`MicrophoneCapture.start(echoCancellation:)` now defaults to `false` and carries
the full explanation. Speaker bleed is handled downstream by
`Transcript.withoutEcho()`, which makes that dedup a correctness requirement
rather than a safety net. Headphones remain the real fix; a proper AEC using the
tap signal as the echo reference is the principled long-term answer, and Oats is
unusually well placed to do it because it already has that reference signal.

### 2. `SpeechChannel.finish()` had a timeout that never fired

The 20 s bound was written as a `withTaskGroup` race between the drain and a
sleep. That cannot work: `withTaskGroup` awaits *every* child before returning,
so when the sleep won, the group still blocked on the drain, and
`finalizeAndFinishThroughEndOfInput()` does not honour cancellation, so
`cancelAll()` could not free it either. The "20 s bound" was an unbounded hang.

It now runs the drain **detached** and waits on a `OneShotSignal` actor that
either the drain or the timeout resolves, whichever comes first. A wedged
analyzer is abandoned rather than awaited. Verified: a run that previously hung
past 140 s now exits in 20 s.

### 3. The timestamps were fine

`bufferStartTime` anchored to a shared origin was never the problem — the last
session's suspicion was misdirected. Both speakers land on one timeline
correctly (`Me 00:03` and `Them 00:03` are the same moment). No change needed.

## Verified working, this session

The command the last session left as "run this next" now passes:

```bash
cd OatsKit && swift build
( sleep 3; say -r 178 "We know it is step three, the workspace invite screen. About forty percent bail there." ) &
timeout 140 ./.build/debug/oats record --title "Echo test" --minutes 0.28 --dir /tmp/oats-meetings
```

Result: live segments appear during recording, both speakers sit on one
timeline, the saved transcript contains each remote sentence **once** labelled
**Them** (4 raw segments → 2 after echo dedup), enhancement runs, notes are
written, and the process exits cleanly in 20 s. `swift test` → 16/16.

### `oats debug-audio`

Added this session. Sweeps all four tap × voice-processing combinations and
reports mic level and tap callback count for each. Use it whenever a recording
comes back empty: every failure mode in this pipeline returns success, so signal
level and callback counts are the only honest evidence. It is what isolated
fault 1 above, and it will catch a recurrence on other hardware.

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
- **Never enable the voice-processing unit while the tap is running.** It kills
  the tap outright and silences the mic after conversion. Full detail above.
- A `withTaskGroup` race is not a timeout. The group awaits all children on
  scope exit, so racing cancellable work against `Task.sleep` only bounds
  anything if the work actually honours cancellation. Several Speech APIs do
  not. Detach the work and signal completion instead.
- Tearing down a VPIO engine is **not** synchronous. Starting another audio
  configuration too soon after it fails with `canPerformIO` (error 560227702),
  which looks exactly like a capture regression. `debug-audio` orders its sweep
  to avoid this rather than sleeping and hoping.
- `readLine()` returns nil instantly when stdin is not a TTY, which silently
  ended recordings when run from a script. The CLI now checks `isatty`.
- The `Info.plist` "unhandled file" build warning from SwiftPM is **cosmetic**.
  The plist is embedded via `-sectcreate` linker flags and TCC reads it
  correctly; verify with `otool -s __TEXT __info_plist ./.build/debug/oats`.
  It was a red herring while chasing the silent-capture bug.
- When capture misbehaves, run the `spike/AudioCaptureSpike` binary first. It is
  a known-good reference, so it separates "the environment or permissions
  broke" from "OatsKit regressed" in about thirty seconds. That call is what
  turned this session's investigation around.
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

## The SwiftUI app

`OatsApp/` — built this session and verified running the full loop on real
audio. A plain SwiftPM package; `scripts/bundle.sh` wraps the binary into
`Oats.app`, because macOS needs a bundle for the menu-bar item and TCC reads the
usage strings from `Contents/Info.plist`. There is no Xcode project on purpose:
`Package.swift` reviews as text and builds on a stock runner.

```
OatsApp/
├── Package.swift
├── Resources/Info.plist        TCC usage strings, bundle identity
├── scripts/bundle.sh           -> build/Oats.app  (ad-hoc signed)
└── Sources/OatsApp/
    ├── OatsApp.swift           @main, MenuBarExtra, NavigationSplitView
    ├── MeetingSession.swift    the only thing that touches MeetingRecorder
    ├── RecordingView.swift     notepad | live transcript
    ├── LibraryView.swift       meeting list + saved-meeting reader
    └── NotesText.swift         block-level Markdown renderer
```

`MeetingSession` exists because `onSegment` fires on whatever thread the
analyzer is on and SwiftUI needs main-actor state; keeping that hop in one place
means no view thinks about threading. It shows the **deduplicated** transcript
live, so the panel matches what will be saved.

Verified by driving the real app: recording starts from ⇧⌘R and the menu bar,
the notepad accepts typing while audio is captured, the transcript panel fills
live with Me/Them labels and auto-scrolls, stopping enhances and saves, and the
library selects the new meeting. **TCC did not re-prompt** for an ad-hoc-signed
bundle on this machine and audio flowed — the handoff's open question about
`.app` behaviour, at least for ad-hoc builds. Note that ad-hoc signing changes
the code identity on every rebuild, so macOS may eventually treat a build as a
new app and ask again.

### ⚠️ The defect the app exposed: the mic channel hallucinates

Running a real meeting through the UI made something obvious that short CLI
tests hid. On the "Me" channel, `SpeechAnalyzer` invents confident sentences out
of room noise. From one 60-second recording where nobody spoke into the mic:

```
 0.27 me  Yeah, that's how I'm going to do.
 4.77 me  What?
10.47 me  I took my dog.
14.85 me  You're the ones four told us about.
19.29 me  Tall back, not back, good looking, needed, say, reason.
```

26 segments, roughly 20 of them fabricated. The "Them" channel was correct
throughout. This is not cosmetic: that text lands in the transcript, feeds the
enhancement prompt, and produced notes about "the price of the property" for a
meeting that had no such discussion.

Why the obvious fix is not obvious: a simple level gate does not separate these.
Measured on this machine, the mic's peak in a *quiet* room is **-23 to -32
dBFS**, which overlaps the level of real speech. It needs an adaptive gate —
track a running noise floor per channel, open on an RMS excursion above it with
a hangover so speech onsets are not clipped, and keep advancing the frame
counter for suppressed buffers so the shared timeline stays correct. Worth
tuning against real speech rather than guessed thresholds, and worth a unit test
with synthetic buffers.

Until that lands, the app is honest but noisy: headphones and a quiet room help,
and the transcript tab shows exactly what the model was given.

## Roadmap from here

1. **Fix the mic hallucination above.** It is the single biggest quality problem
   and it degrades the enhancement, which is the product's whole point.
2. **Echo, properly.** Today's defence is transcript-level dedup, which works
   but is downstream and lossy by nature — it can only drop whole utterances,
   and it deliberately refuses to touch anything under four words. Since Oats
   already captures the exact signal being played, a real AEC with the tap as
   reference is achievable and would let "Me" survive genuine interruptions on
   speakers. The adaptive gate and the AEC are the same spike, really.
3. **App polish.** Editing a saved meeting's title, re-running enhancement with
   a different template, deleting a meeting, and a settings pane for the storage
   location. None are wired up yet.
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
