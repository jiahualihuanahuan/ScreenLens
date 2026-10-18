# ScreenLens

Menu bar app for macOS with global hotkeys for on-device screen translation and word-select search.

## Hotkeys

- **⌥⌘T** — Translate the full screen on-device. Translated text is drawn in place over the original text (with a solid cover so the original is hidden). The overlay stays until you move the mouse, click, scroll, or type. Press the hotkey again to translate the current screen.
- **⌥⌘S** — Word-select search. Click a word and drag to expand the selection to adjacent words. On release, the text is copied to the clipboard and searched on Google in your default browser.

Uses Apple Vision for OCR (with word-level bounding boxes) and the Translation framework for private, on-device translation.

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
- Global hotkeys: ⌥⌘T (translate), ⌥⌘S (word-select search)
- Target language picker in the menu (default: zh)
- Full-screen capture → Vision OCR → on-device translation → in-place overlay with solid covers over original text
- Translation overlay stays until user input (mouse move, click, scroll, or key)
- Word-level selection: click a word, drag to include adjacent words
- Selected text is copied to the clipboard and opened in Google search
- App stays running in the menu bar until you quit from the menu or terminal

## Notes

- Translation assumes English source and requires macOS 26+ for the direct TranslationSession API. Language packs must be pre-installed.
- Overlay positioning uses Vision bounding boxes converted to screen coordinates.
- Multi-monitor support is basic (uses main screen).
- Word selection works best on clear, high-contrast text.
