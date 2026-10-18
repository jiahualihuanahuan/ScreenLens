# ScreenLens

Menu bar app for macOS with global hotkeys:

- **⌥⌘T** — Translate the full screen on-device and show a transparent overlay with translated text drawn in place
- **⌥⌘S** — Select a region, OCR it, and search on Google in the default browser

Uses Apple Vision for OCR (with bounding boxes) and the Translation framework for private, on-device translation.

## Requirements

- macOS 15+ (macOS 26+ recommended for full TranslationSession support)
- Screen Recording permission (System Settings > Privacy & Security)
- Translation language packs installed (System Settings > General > Language & Region > Translation Languages)

## Build & Run

```bash
git clone https://github.com/jiahualihuanahuan/ScreenLens.git
cd ScreenLens
swift build -c release
.build/release/ScreenLens
```

Grant Screen Recording permission when prompted.

## Features

- Menu bar icon (no Dock icon)
- Global hotkeys: ⌥⌘T (translate), ⌥⌘S (select & search)
- Target language picker in the menu (default: zh)
- Full-screen capture → Vision OCR with bounding boxes → on-device translation → transparent overlay
- Overlay dismisses on click, Escape, or after 8 seconds
- Interactive region selection for Google search

## Notes

- Translation currently assumes English source and requires macOS 26+ for the direct TranslationSession API. Language packs must be pre-installed.
- Overlay positioning uses Vision bounding boxes converted to screen coordinates.
- Multi-monitor support is basic (uses main screen).
