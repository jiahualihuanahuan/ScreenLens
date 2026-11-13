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

## Install & Run

### Option 1: Build and install with `bundle.sh` (recommended)

```bash
git clone https://github.com/jiahualihuanahuan/ScreenLens.git
cd ScreenLens
chmod +x bundle.sh
./bundle.sh
```

This builds a release binary, creates `/Applications/ScreenLens.app`, signs it ad-hoc, and launches it. The app then runs independently of Terminal.

### Option 2: Download the prebuilt app

Download `ScreenLens.app` from the latest [Release](https://github.com/jiahualihuanahuan/ScreenLens/releases), move it to `/Applications`, and open it.

### Option 3: Run the binary directly (development)

```bash
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

## How screen size and content detection work

- **Any display, any scale.** The capture is taken from the display that holds most of the target region (a window can straddle two monitors) at that display's real pixels-per-point (ScreenCaptureKit `pointPixelScale`, Retina, "More Space" scaled modes and 1x externals). Quartz (top-left) and AppKit (bottom-left) coordinates are converted relative to the primary display, so monitors placed left/right/above/below work.
- **Translate main content (⌥⌘T).** Order of preference: (1) the focused window's `AXWebArea` (browsers/Electron) or main `AXScrollArea` (document apps), which already excludes the menu bar, tabs, URL bar and bookmarks bar; (2) the window minus the measured bottom of its `AXToolbar` / tab strip; (3) the window minus a heuristic title-bar/toolbar margin capped at 24% of the window height (also used without Accessibility permission); (4) the active display's usable area (below the menu bar/notch, above the Dock). Text-block filters use points, not fractions of the capture, so they behave the same on every screen size.
- **Select & search (⌥⌘S).** Several OCR passes run on the native-resolution capture: overlapping upscaled tiles for tiny text, a full-size pass for body text/headings, and downscaled passes for large and giant hero text. Duplicates across passes are merged.
- The platform-independent logic lives in `Sources/ScreenLensCore` and is unit tested: `swift test` (works on macOS and Linux).

## Notes

- Translation assumes English source and requires macOS 26+ for the direct TranslationSession API. Language packs must be pre-installed.
- Word selection works best on clear, high-contrast text.
- Accessibility permission gives the most exact content area. Without it ScreenLens falls back to window bounds plus a heuristic margin; use ⌥⌘A to drag a region when the result is off.
