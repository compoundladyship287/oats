# Open-Source Local Granola — Implementation Plan

## Context

The user wants to build a Granola-style AI meeting notes app that is **entirely local** and **open source**. Granola's own architecture is only local at the capture layer: audio streams to Deepgram/AssemblyAI, transcripts live on AWS, and note-enhancement runs on OpenAI/Anthropic — plus training-on-your-data by default, a 25-meeting lifetime free cap, and recent lock-in moves (encrypted local cache killed community export tools). That's the gap this project fills.

Research (Aug 2026) shows the OSS space is crowded but wobbly: Meetily (28k★) stalled and paywalled diarization; Hyprnote rebranded twice (now Anarlog) with the team focused on a closed cloud sibling; Amurex is dead; screenpipe pivoted. **The clearest unfilled niches:** (1) Granola's signature *notepad-first "enhance my rough notes"* flow — almost nobody replicates it; (2) trustworthy governance (no open-core bait-and-switch); (3) deep calendar auto-detect/auto-start; (4) usable local diarization.

### Locked decisions (from user)
- **Platform:** macOS first (Apple Silicon, macOS 14.4+ floor); architecture must not preclude Windows/Linux later.
- **AI locality:** Strictly local — no network calls for AI, ever. (localhost inference like Ollama/LM Studio is fine.)
- **Goal:** Real OSS community project — optimize for contributors, docs, CI, longevity.
- **Stack:** evidence-based (below).

## Product definition (v1)

A menu-bar-plus-window macOS app:
1. Detects an upcoming/starting meeting from the calendar (or manual start), begins capturing **mic + system audio** — no bot joins the call, works with Zoom/Meet/Teams/anything.
2. Shows a minimal **notepad** during the meeting; user types rough fragments. Live transcript runs in a side panel with "Me/Them" channel-based speaker labels.
3. On meeting end, a **local LLM merges the user's rough notes (skeleton) with the transcript (flesh)** into polished notes that preserve the user's structure — the Granola signature move. Templates shape the output per meeting type.
4. Everything stored locally (SQLite + Markdown export). Audio recording optionally kept (a thing Granola *can't* offer — lets users verify the transcript).
5. Later: ask-AI chat over meetings, real diarization, folders.

**Differentiators vs existing OSS:** notepad-first enhance flow, strictly-local guarantee (a "zero network calls" stance you can verify with Little Snitch), kept audio recordings, honest MIT governance with no Pro tier.

## Tech stack (evidence-based)

| Layer | Choice | Why |
|---|---|---|
| Shell | **Tauri v2** (Rust core, React+TypeScript frontend) | What every credible OSS peer chose (Meetily, Anarlog, screenpipe) → liftable patterns exist for the two hardest problems (capture, local inference). ~3–20MB bundle vs Electron's 85–244MB for an always-running companion app. TS frontend keeps the casual-contributor door open; cross-platform path preserved. |
| System audio | **Core Audio process taps** (`CATapDescription` + `AudioHardwareCreateProcessTap`), global tap excluding own PID, via Swift bridged with **swift-rs** (or Rust `cidre` bindings, Anarlog's approach) | macOS 14.2+ API; "System Audio Recording Only" TCC permission — no Screen Recording grant, no purple indicator, no Sequoia re-approval nags. Reference impl: `insidegui/AudioCap`. Known traps documented (raw IOProc not AVAudioEngine; aggregate-device ordering; signed binary required for TCC prompt). |
| Mic | cpal (Rust) mic stream, kept as a **separate channel** from system audio | Separate channels give free "Me vs Them" speaker attribution + easier echo cancellation. |
| ASR | **Parakeet TDT 0.6B v3 via FluidAudio** (CoreML/ANE, Swift SDK) — 155x realtime on M-series, 2.5% WER, CC-BY-4.0. Silero-VAD-gated chunked streaming. **whisper.cpp large-v3-turbo (whisper-rs)** as cross-platform/multilingual fallback. | Parakeet on ANE is the current best local ASR on Mac (Muesli proves it: ~0.13s latency). FluidAudio also ships VAD + diarization in the same SDK. |
| Diarization | Phase 1: channel-based Me/Them (mic vs system). Phase 2: **FluidAudio community-1 diarization** (CoreML, 10.6% DER @ 323x RT), reconciled with word timestamps. | Universal weak point in the space; the two-phase approach ships value early. |
| LLM | **llama.cpp embedded in-process** (llama-cpp-2 Rust crate) with **Qwen3-8B Q4** default (16GB Macs) / **Qwen3-30B-A3B-Instruct-2507** (32GB), JSON-schema→GBNF constrained decoding for structured outputs. Auto-detect **Ollama/LM Studio** (localhost) as optional backends. | No sidecar signing pain, no daemon dependency, guaranteed-valid structured output. A 60-min meeting (~8–15K tokens) fits 32K context in one pass. |
| Storage | SQLite (rusqlite, WAL) + Markdown export directory (Obsidian-friendly) | Local-first, greppable, no lock-in — pointed contrast with Granola's encrypted cache. |
| Calendar | EventKit via Swift bridge (Apple Calendar, which syncs Google/Outlook accounts already on the Mac) | Avoids OAuth-to-Google network complexity in v1 while covering most users; auto-detect meeting start from event + running meeting-app heuristic. |

## Repository layout

```
app/
  src/                    # React + TS frontend (notepad, transcript panel, library)
  src-tauri/
    src/                  # Rust core: session orchestration, storage, llm, asr
    swift/                # Swift package: CATap capture, FluidAudio ASR/diarization, EventKit
crates/
  capture/                # audio capture abstraction (macOS impl now; win/linux traits ready)
  transcribe/             # ASR engine trait: fluid-audio (via FFI), whisper-rs
  enhance/                # LLM pipeline: prompts, templates, GBNF schemas
docs/                     # architecture, CONTRIBUTING, model matrix
.github/workflows/        # CI: fmt+clippy+tests, TS lint+test, macOS build, release signing
```

## Milestones

**M0 — Scaffold + capture spike (the risk killer).** Tauri v2 app scaffolded; Swift package doing CATap system-audio + cpal mic capture writing WAVs; TCC permission flow working with a signed dev build. *This spike validates the hardest, least-documented part first.* Port patterns from AudioCap + Anarlog's capture crates.

**M1 — Live transcription.** FluidAudio/Parakeet streaming into a live transcript view with Me/Them channel labels; whisper.cpp fallback path; meeting session lifecycle (start/stop/auto-stop on silence); SQLite persistence.

**M2 — The Granola move.** Notepad editor (during meeting) + post-meeting enhance pipeline: rough notes + transcript → llama.cpp with GBNF-constrained output → polished notes preserving user structure; template system (1-on-1, standup, customer call, custom); Markdown export. Model download manager (first-run pull of Parakeet + Qwen3 with checksums).

**M3 — Calendar + polish.** EventKit integration: upcoming-meeting detection, auto-start prompt, event title/attendees as enhancement context; menu-bar quick-start; audio recording retention (optional); settings.

**M4 — OSS launch.** MIT license, README with honest comparison table, CONTRIBUTING + architecture docs, CI (build/test/sign/notarize on tags), GitHub issue templates, landing page, Show HN / r/LocalLLaMA launch. Signed + notarized DMG via Developer ID (process taps effectively require non-App-Store distribution).

**Post-v1 roadmap (documented, not built):** FluidAudio diarization with name attribution, ask-AI chat over meetings (folder-scoped), Windows (WASAPI loopback in Rust), Linux (PipeWire monitors), Apple SpeechTranscriber/Foundation Models as zero-download tiers on macOS 26+, Voxtral Realtime when MLX ports mature.

## Key risks & mitigations
- **CATap sharp edges** (silent zero-sample failures, TCC only prompts for signed builds) → M0 spike first; copy AudioCap/Anarlog exactly; document setup for contributors (needs Apple dev cert even for local dev of capture code).
- **Echo/double-capture** (mic re-hears speakers) → separate channels + Silero VAD per channel; ship speaker-aware AEC later; headphone use masks this for most video calls initially.
- **Strictly-local quality ceiling** → Qwen3-30B-A3B on 32GB Macs is genuinely good at summarization; the enhance-notes task (rewrite user's own skeleton with transcript evidence) is easier than open-ended summarization, which favors small models.
- **Crowded space** → differentiate on the enhance flow + strict locality + governance; say so plainly in the README.

## Verification
- M0: run app, play music + speak; verify WAV contains both channels; verify TCC prompt appears once and permission shows under "System Audio Recording Only".
- M1: join a real Zoom/Meet test call; verify live transcript accuracy and Me/Them labeling; kill network (Wi-Fi off) and confirm everything still works — this is the acceptance test for "strictly local" at every milestone.
- M2: golden-file tests for the enhance pipeline (fixed transcript + rough notes → structured output validates against JSON schema); manual quality review across templates.
- CI: cargo test + clippy + fmt, vitest for frontend, macOS build job on every PR.

## First concrete steps (on approval)
1. `git init`, scaffold Tauri v2 app with React+TS template.
2. Create Swift package with CATap capture (port from AudioCap), bridge via swift-rs, wire a "record 10s of system audio+mic to WAV" dev command.
3. Set up signing config + entitlements (`NSAudioCaptureUsageDescription`, `NSMicrophoneUsageDescription`, `com.apple.security.device.audio-input`).
