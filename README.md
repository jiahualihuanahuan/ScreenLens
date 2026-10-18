# ScreenLens

Menu bar app for macOS with global hotkeys for on-device screen translation and word-select search.

## Hotkeys

- **⌥⌘T** — Translate the focused region (or full screen) on-device. Uses Accessibility to target the active text area when available, otherwise captures the full screen. Translated text is drawn in place with solid covers. The overlay stays until you move the mouse, click, scroll, or type. Press the hotkey again to re-translate.
- **⌥⌘S** — Word-select search. Click a word and drag to expand the selection. On release, the text is copied to the clipboard and searched on Google.

Uses Apple Vision for OCR and the Translation framework for private, on-device translation. Capture prefers ScreenCaptureKit for regions.

## Requirements

- macOS 15+ (macOS 26+ recommended for full TranslationSession support)
- Screen Recording permission (System Settings > Privacy & Security)
- Accessibility permission (recommended for focused-region targeting)
- Translation language packs installed (System Settings > General > Language & Region > Translation Languages)

## Build & Run

```bash
git clone https://github.com/jiahualihuanahuan/ScreenLens.git
cd ScreenLens
swift build -c release
.build/release/ScreenLens
```

Grant Screen Recording (and Accessibility) permission when prompted.

## Features

- Menu bar icon (no Dock icon)
- Global hotkeys: ⌥⌘T (translate), ⌥⌘S (word-select search)
- Target language picker in the menu (default: zh)
- Non-activating floating panel (does not steal focus from the frontmost app)
- Focused-region targeting via Accessibility (AXUIElement), with full-screen fallback
- ScreenCaptureKit region capture when a focused area is found
- In-place translation overlay with solid covers over original text
- Overlay stays until user input (mouse move, click, scroll, or key)
- Word-level selection: click a word, drag to include adjacent words
- Selected text is copied to the clipboard and opened in Google search
- Translation history appended to `~/Library/Application Support/ScreenLens/Translation_History.md`
- App stays running in the menu bar until you quit

## Notes

- Translation assumes English source and requires macOS 26+ for the direct TranslationSession API. Language packs must be pre-installed.
- Overlay positioning uses Vision bounding boxes converted to screen coordinates.
- Multi-monitor support is basic (uses main screen).
- Word selection works best on clear, high-contrast text.
- Accessibility permission improves region targeting; without it the app falls back to full-screen capture.
