#!/usr/bin/env bash
#
# Builds a small, believable meeting library for the demo recording.
#
# The real library on a dev machine is full of "Meeting Sunday 12:48" and
# half-broken test captures. Recording against that makes the product look
# unfinished for reasons that have nothing to do with the product.
#
# These are written in Oats' own on-disk format — plain folders of Markdown and
# JSON — which is itself the point being demonstrated.
set -euo pipefail

DIR="${1:-$HOME/Oats-Demo}"
rm -rf "$DIR"
mkdir -p "$DIR/Customers"

meeting() {
    local path="$1" id="$2" title="$3" started="$4" ended="$5" duration="$6"
    local folder="$7" notes="$8" transcript="$9" rough="${10}"
    mkdir -p "$path"

    python3 - "$path" "$id" "$title" "$started" "$ended" "$duration" "$folder" \
        "$notes" "$transcript" "$rough" <<'PY'
import json, sys, os
path, mid, title, started, ended, duration, folder, notes, transcript, rough = sys.argv[1:11]

segments = []
t = 2.0
for line in transcript.strip().split("\n"):
    speaker, text = line.split("|", 1)
    words = max(1, len(text.split()))
    segments.append({
        "id": f"{mid[:8]}-{len(segments):04d}-4000-8000-000000000000",
        "speaker": speaker,
        "text": text,
        "start": round(t, 2),
        "end": round(t + words * 0.42, 2),
    })
    t += words * 0.42 + 0.8

meeting = {
    "id": mid,
    "title": title,
    "startedAt": started,
    "endedAt": ended,
    "roughNotes": rough,
    "transcript": {"segments": segments},
    "enhancedNotes": notes,
    "templateID": "general",
    "recordedDuration": float(duration),
}
if folder:
    meeting["folder"] = folder

with open(os.path.join(path, "meeting.json"), "w") as f:
    json.dump(meeting, f, indent=2, sort_keys=True)

with open(os.path.join(path, "notes.md"), "w") as f:
    f.write(f"---\ntitle: {title}\ndate: {started}\n---\n\n# {title}\n\n{notes}\n")

with open(os.path.join(path, "transcript.md"), "w") as f:
    f.write(f"# Transcript — {title}\n\n")
    for s in segments:
        m, sec = divmod(int(s["start"]), 60)
        label = "Me" if s["speaker"] == "me" else "Them"
        f.write(f"**{label}** `{m:02d}:{sec:02d}`  \n{s['text']}\n\n")
PY
}

meeting "$DIR/2026-08-07-1030-onboarding-review" \
    "A1B2C3D4-0001-4000-8000-000000000001" \
    "Onboarding review" "2026-08-07T10:30:00Z" "2026-08-07T11:02:00Z" 1920 "" \
"### Discussion

* Roughly 40% of new workspaces stall at the invite step.
* Priya pulled the funnel: the drop is concentrated on the second day, not the first.

### Decisions

* Move the invite prompt after the first note is written.

### Action items

* Priya to ship the reordered flow on Thursday." \
"them|About forty percent of new workspaces never get past the invite step.
me|Is that day one or later?
them|Day two mostly. They come back, see the invite screen again, and leave.
me|Then we should move the invite prompt after they have written something.
them|Agreed. I can have that ready by Thursday." \
"- invite step drop
- when?
- move it later?"

meeting "$DIR/2026-08-08-1415-weekly-1-1" \
    "A1B2C3D4-0002-4000-8000-000000000002" \
    "Weekly 1:1" "2026-08-08T14:15:00Z" "2026-08-08T14:41:00Z" 1560 "" \
"### Discussion

* Migration is done apart from the reporting jobs.

### Action items

* Pair on the reporting jobs on Monday." \
"me|How did the migration land?
them|Everything is across except the reporting jobs, they need a rewrite.
me|Want to pair on those Monday?
them|Yes, that would help." \
"- migration status
- anything blocked?"

meeting "$DIR/Customers/2026-08-08-1600-northwind-renewal" \
    "A1B2C3D4-0003-4000-8000-000000000003" \
    "Northwind renewal" "2026-08-08T16:00:00Z" "2026-08-08T16:35:00Z" 2100 "Customers" \
"### Pain points

* \"We are exporting to spreadsheets twice a week just to see anything.\"

### Feature requests

* Scheduled exports.

### Action items

* Send the API docs before Friday." \
"them|We are exporting to spreadsheets twice a week just to see anything.
me|Would scheduled exports solve that, or do you need the API?
them|Scheduled exports would cover most of it. The API for the rest.
me|I will send the API docs before Friday." \
"- northwind renewal
- what is painful today"

echo "seeded $(find "$DIR" -name meeting.json | wc -l | tr -d ' ') meetings in $DIR"
