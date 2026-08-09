# media/

Tooling that produced the demo video linked from the main
[README](../README.md). Nothing here is mocked — it drives the real app.

```
media/
├── scripts/
│   ├── seed-demo-library.sh   writes a believable meeting library in Oats'
│   │                          own on-disk format (plain Markdown + JSON),
│   │                          so the recording never shows real user data
│   ├── record-demo.sh         drives Oats via real keystrokes/shortcuts,
│   │                          with `say` playing the far side of a call
│   │                          into the system audio Oats is tapping
│   └── ...
└── DemoBuilder/                a small AVFoundation + Core Animation tool
                                 (no ffmpeg) that jump-cuts the raw capture,
                                 adds a moving camera per shot, captions, a
                                 title and an outro, and renders 1080p30
```

## Reproducing it

```bash
cd OatsApp && ./scripts/bundle.sh release   # build Oats.app once

cd ../media
./scripts/seed-demo-library.sh ~/Oats-Demo
./scripts/record-demo.sh raw/demo-raw.mov   # ~2 minutes; do not touch the
                                             # keyboard/mouse while it runs

cd DemoBuilder && swift build -c release
.build/release/DemoBuilder build ../raw/demo-raw.mov ../oats-demo.mp4
```

`DemoBuilder contact <video> <outDir> [everyNSeconds]` dumps a contact sheet of
frames — use it to pick cut points before editing `DemoFilm.swift`'s `shots`
array, rather than guessing at timings.

The raw capture and rendered video are gitignored: reproducible from the
scripts above, and committing video into git history bloats every future
clone. The finished film ships as a
[GitHub Release asset](https://github.com/yuvrajadhikari/oats/releases) instead.
