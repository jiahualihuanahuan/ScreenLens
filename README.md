# ScreenLens

Menu bar app for macOS with global hotkeys:

- **⌥⌘T** — Translate the full screen on-device and show an overlay
- **⌥⌘S** — Select a region, OCR it, and search on Google

Uses Apple Vision for OCR and the Translation framework for private, on-device translation.

## Requirements

- macOS 15+
- Screen Recording permission
- Translation language packs installed

## Build & Run

```bash
git clone https://github.com/jiahualihuanahuan/ScreenLens.git
cd ScreenLens
swift build -c release
.build/release/ScreenLens
```

Grant Screen Recording permission when prompted.

## Status

Initial scaffold. Menu bar icon, global hotkeys, and stubs for translate/search are in place. Overlay drawing and real capture coming next.
