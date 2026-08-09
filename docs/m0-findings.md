# M0 findings — measured, not assumed

Everything here was verified on the dev machine (MacBook Air, Apple M5, 16 GB,
macOS 26.6) with the spikes in `spike/AudioCaptureSpike`. Numbers are from
actual runs.

## The whole pipeline runs locally with zero downloads

capture → transcribe → enhance, all on-device, no network, no bundled weights:

| Stage | Mechanism | Result |
|---|---|---|
| System audio | Core Audio process tap (macOS 14.2+) | 1183 callbacks, **0.00% frame loss** |
| Microphone | `AVAudioEngine` input tap, separate stream | clean, 48 kHz mono |
| Transcription | Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26) | **~44× realtime**, near word-perfect |
| Note enhancement | Apple Foundation Models on-device (~3B) | 4.5 s for a 241-word transcript |

## Core Audio process taps

Confirmed working without a virtual audio driver and without Screen Recording
permission. Notable details the docs gloss over:

- `CATapDescription(stereoGlobalTapButExcludeProcesses:)` takes **Core Audio
  process object IDs, not PIDs**. Passing a raw PID compiles once you cast it
  and silently excludes nothing. Translate first with
  `kAudioHardwarePropertyTranslatePIDToProcessObject`.
- **The tap delivers interleaved stereo.** `AVAudioPCMBuffer.floatChannelData`
  must be read with `buffer.stride`. Treating it as non-interleaved captures
  every other sample at half speed — and the failure looks like a bad ASR model,
  not a bug. This cost the most time to find; the tell was a median
  sample-to-sample delta of exactly 0 and every value repeated twice.
- The aggregate device must have the **real output device as main sub-device**
  with the tap as a sub-tap. Inverting that returns `noErr` and yields silence.
- A raw IOProc is required; `AVAudioEngine` cannot be pointed at the aggregate.
- No TCC prompt appeared when running as a plain CLI binary from a terminal on
  macOS 26.6 — the permission attaches to the launching app. A signed `.app`
  needs `NSAudioCaptureUsageDescription` and its own grant; verify before
  assuming the packaged app behaves like the spike.

### Verifying capture actually worked

Every documented tap failure returns `noErr` and hands back silence, so the
spike reports peak/RMS in dBFS per stream and separately tracks frame
continuity from the device timestamp. "Exited cleanly" proves nothing; signal
level and 0% loss do.

## Transcription quality (Apple SpeechAnalyzer)

Reference (clean file, no capture): *"Segment one. Oats captures system audio
locally on device."* — verbatim.

Through the system-audio tap, after the interleaving fix: *"Segment one. Oats
captures system audio locally on device. Segment two. The quick brown fox jumps
over the lazy dog, segment 3."* — verbatim apart from the proper noun.

Good enough to be the default on macOS 26. Parakeet/whisper.cpp remain the
portable fallback for older macOS and other platforms.

## Note enhancement quality (Apple Foundation Models)

Given rough notes (`onboarding drop-off / - step 3 problem / - fix?`) and a
241-word transcript, the on-device model kept the user's headings and filled in
the 40% drop-off figure, the workspace-invite screen, the skip-button fix, the
owner (Priya), and both Q3 deferrals.

It also **missed an explicitly stated decision** — revisit mobile at end of Q2
gated on week-4 retention clearing 30% (currently 22%) — and slightly garbled
the Priya action item into a deadline that was never stated.

Conclusion: a genuinely useful zero-download tier, not the quality ceiling. The
4,096-token context window also means a real hour-long meeting needs chunking.
A larger local model (Qwen3-8B class) should remain the quality default, with
this as the no-setup option.

## Open questions for M1

- Does the TCC prompt behave the same from a signed, notarized `.app`?
- Echo cancellation: with speakers (not headphones) the mic re-hears the far
  end. Both streams captured it here; needs AEC before diarization matters.
- Streaming: these spikes transcribe a finished file. Live transcription needs
  `SpeechAnalyzer` fed from the tap with volatile results.
