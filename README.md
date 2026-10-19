# ScreenLens

Menu bar app for macOS with global hotkeys for on-device screen translation and word-select search. Uses Apple Vision for OCR and the Translation framework for private, offline translation.

## Hotkeys

- **⌥⌘T** — Translate the active window. Uses Accessibility to locate the focused window, then OCRs and translates it in place. The overlay stays until you click, scroll, or type.
- **⌥⌘A** — Drag to select an area to translate. Release to OCR and translate just that region.
- **⌥⌘S** — Word-select search. Click a word and drag to expand the selection. On release, the text is copied to the clipboard and searched on Google.

## Requirements

- macOS 15+ (macOS 26+ recommended for full TranslationSession support)
- Screen Recording permission (System Settings → Privacy & Security → Screen Recording)
- Accessibility permission (System Settings → Privacy & Security → Accessibility)
- Translation language packs installed (System Settings → General → Language & Region → Translation Languages)

## Build & Run

```bash
git clone https://github.com/jiahualihuanahuan/ScreenLens.git
cd ScreenLens
swift build -c release
.build/release/ScreenLens
```

Grant Screen Recording and Accessibility when prompted. The menu bar icon shows the current permission status — click it to open the relevant System Settings pane.

## Features

- Menu bar icon with live permission status (Accessibility / Screen Recording)
- Global hotkeys: ⌥⌘T (active window), ⌥⌘A (drag area), ⌥⌘S (word-select search)
- Target language picker in the menu (default: zh-Hans), saved across launches
- Non-activating floating panel (does not steal focus from the frontmost app)
- Active-window targeting via Accessibility (AXUIElement)
- Drag-to-select area translation
- ScreenCaptureKit region capture
- In-place translation overlay with solid covers over original text
- Overlay stays until click, scroll, or key (mouse move alone does not dismiss)
- Word-level selection: click a word, drag to include adjacent words
- Selected text is copied to the clipboard and opened in Google search
- Recent translations submenu (click to copy)
- Translation history appended to `~/Library/Application Support/ScreenLens/Translation_History.md`
- Open history file or reveal folder from the menu
- Clear overlay from the menu
- Launch at Login toggle (requires the app to be in `/Applications`)
- App stays running in the menu bar until you quit

## Notes

- Translation assumes English source and requires macOS 26+ for the direct TranslationSession API. Language packs must be pre-installed.
- Overlay positioning converts between Quartz (top-left) and AppKit (bottom-left) coordinates.
- Multi-monitor support is basic (uses main screen for some operations).
- Word selection works best on clear, high-contrast text.
- Accessibility permission is required for active-window translation. Without it, use ⌥⌘A to drag a region.
