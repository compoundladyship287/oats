#!/usr/bin/env bash
#
# Records the raw take for the demo film — onboarding from the very top,
# through a real recorded meeting, to the finished notes.
#
# Nothing is mocked: real keystrokes drive the actual app while `say` plays the
# far side of the call into the audio Oats is tapping. The edit (DemoBuilder)
# jump-cuts this ~95s take down to ~40s; the sleeps below are the timeline the
# cut list in DemoFilm.swift refers to, so keep them in sync.
set -euo pipefail

cd "$(dirname "$0")/../.."

APP="OatsApp/build/Oats.app"
OUT="${1:-media/raw/demo-raw.mov}"
STORE="$HOME/Oats-Demo"

# Capture rect in points: exactly the window, nothing else. The desktop never
# appears in frame, and 1280x720 points is 2560x1440 pixels — exactly 16:9, so
# zooms in the edit stay uniform.
WIN_X=95
WIN_Y=115
RECT_X=$WIN_X
RECT_Y=$WIN_Y
RECT_W=1280
RECT_H=720

mkdir -p "$(dirname "$OUT")"
# screencapture refuses to overwrite and fails at the very end, after the whole
# take has been performed — losing the recording while looking like success.
rm -f "$OUT"

key() { osascript -e "tell application \"System Events\" to keystroke $1" >/dev/null 2>&1; }
combo() { osascript -e "tell application \"System Events\" to keystroke \"$1\" using {$2}" >/dev/null 2>&1; }
return_key() { osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1; }
front() { osascript -e 'tell application "Oats" to activate' >/dev/null 2>&1; sleep 0.6; }
say_line() { say -r 172 "$1"; }

# ── Stage ────────────────────────────────────────────────────────────────────
osascript -e 'tell application "Oats" to quit' >/dev/null 2>&1 || true
sleep 2

defaults write app.oats.Oats storagePath -string "$STORE"
defaults write app.oats.Oats appearance -string light
# The film opens on onboarding, so first-run state is part of the take.
defaults write app.oats.Oats hasCompletedOnboarding -bool false
# Park the pill inside the window's top-right, well inside the capture rect.
defaults write app.oats.Oats overlayOrigin -string "{1000, 770}"

open "$APP"
sleep 8
front
osascript -e "tell application \"System Events\" to tell process \"Oats\"
  set position of window 1 to {$WIN_X, $WIN_Y}
  set size of window 1 to {1280, 720}
end tell" >/dev/null 2>&1
sleep 2

echo "==> recording to $OUT"
screencapture -v -V 112 -x -R${RECT_X},${RECT_Y},${RECT_W},${RECT_H} "$OUT" &
CAPTURE=$!
sleep 3

# ── The take (capture time in comments) ──────────────────────────────────────
front
sleep 2                       # t0–2    welcome: animated logo
return_key                    # Get Started
sleep 3                       # t2–5    permissions, all green
return_key                    # Continue
sleep 3                       # t5–8    "You're set up"
return_key                    # Start Using Oats
sleep 2.5                     # t8–10.5 home screen

combo "n" "command down"      # t10.5   New Meeting sheet
sleep 2
key '"Pricing sync"'
sleep 1
return_key                    # t14.5   start recording
sleep 12                      # model preparation — cut in the edit

# t≈26.5: live. Notes typed between spoken lines, synchronously — a background
# `say` plus bare `wait` once froze the whole take by waiting on the capture.
#
# The dialogue must clear NoteEnhancer.minimumTranscriptWords (40 spoken
# words) with margin, or the film ends on "transcript only" instead of the
# written-up notes that are the whole payoff. This script is ~75 words.
key '"- renewal pricing"'
sleep 1
say_line "So the main thing today is the renewal pricing for Northwind."
sleep 1
return_key
key '"- scheduled exports = blocker"'
sleep 1
say_line "They are asking for scheduled exports before they commit to the annual plan."
sleep 1
say_line "Right now they export to spreadsheets twice a week just to see anything, and that is their biggest complaint."
sleep 1
return_key
key '"- who owns the deck?"'
sleep 1
say_line "Priya can own the pricing deck, and legal still needs to sign off on the new terms."
sleep 1
return_key
key '"- thursday?"'
sleep 1
say_line "Let us aim to have the deck and the sign off ready by Thursday."
sleep 1.5                     # t≈60

osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
sleep 4                       # t≈61–65 pill floating over Finder
front
sleep 1.5

combo "p" "command down, shift down"   # t≈67 pause
sleep 3
combo "p" "command down, shift down"   # t≈70 resume
sleep 1.5

combo "r" "command down, shift down"   # t≈72 stop → drain → enhance → save
sleep 38                                # notes on screen from ≈t95

echo "==> waiting for capture to finish"
wait "$CAPTURE" 2>/dev/null || true
sleep 1
echo "==> wrote $OUT"
