import AppKit
import HotKey
import Vision
import Translation
import NaturalLanguage
import ScreenCaptureKit
import ApplicationServices
import ServiceManagement
import CoreImage
import Foundation

// MARK: - Models

struct TextItem: Sendable {
    let text: String
    let boundingBox: CGRect // Vision normalized (0...1, bottom-left origin)
    let avgLineHeight: CGFloat
    let confidence: Float
}

struct WordBox: Sendable {
    let word: String
    let rect: CGRect // Vision normalized (0...1, bottom-left origin)
    let confidence: Float
}

struct TranslatedBlock: Sendable {
    let sourceText: String
    let translatedText: String
    let boundingBox: CGRect // Vision normalized (0...1, bottom-left origin)
    let avgLineHeight: CGFloat
}

struct ActiveContentTarget: Sendable {
    let quartzRect: CGRect
    let isExactContentArea: Bool // True when resolved via AXWebArea / AXScrollArea
    let isBrowserWindow: Bool
}

// MARK: - Non-Constrained Floating Panel

final class FloatingPanel: NSPanel {
    var allowsKey: Bool = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { allowsKey }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

// MARK: - App Delegate (Menu Bar & CLI Daemon)

@available(macOS 14.0, *)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let cliCommandNotification = Notification.Name("com.screenlens.app.cliCommand")

    var statusItem: NSStatusItem!
    var translateHotKey: HotKey?
    var areaTranslateHotKey: HotKey?
    var searchHotKey: HotKey?

    var overlayWindow: NSWindow?
    var selectionWindow: NSWindow?
    var targetLanguage: String = UserDefaults.standard.string(forKey: "TargetLanguage") ?? "zh-Hans"
    var inputMonitors: [Any] = []
    var isTranslating = false
    var recentHistory: [(source: String, target: String)] = []
    var initialCLICommand: String?

    /// Remembers the last frontmost non-ScreenLens app PID
    var lastActiveAppPID: pid_t?

    private var axStatusItem: NSMenuItem!
    private var screenStatusItem: NSMenuItem!
    private var historySubmenu: NSMenu!
    private var launchAtLoginItem: NSMenuItem!

    nonisolated private static let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])

    private let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser", // Arc
        "company.thebrowser.dia",     // Dia
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",         // Orion
        "ai.perplexity.comet",
        "com.openai.atlas"
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastActiveAppPID = front.processIdentifier
        }

        // Track whenever user switches apps so Menu Bar clicks still know the target app
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != ownPID {
                Task { @MainActor in
                    self?.lastActiveAppPID = app.processIdentifier
                }
            }
        }

        // Listen for CLI commands forwarded from secondary invocations (e.g., `screenlens --translate`)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleCLIDistributedCommand(_:)),
            name: Self.cliCommandNotification,
            object: nil
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "ScreenLens")
            button.imagePosition = .imageLeading
        }

        setupMenu()
        setupHotKeys()

        if let cmd = initialCLICommand {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                self.dispatchCLICommand(cmd)
            }
        }
    }

    @objc private func handleCLIDistributedCommand(_ note: Notification) {
        guard let cmd = note.userInfo?["command"] as? String else { return }
        dispatchCLICommand(cmd)
    }

    private func dispatchCLICommand(_ cmd: String) {
        switch cmd {
        case "--translate", "-t":
            translateScreen()
        case "--area", "-a":
            translateSelectedArea()
        case "--search", "-s":
            selectAndSearch()
        case "--clear", "-c":
            clearOverlayAction()
        default:
            break
        }
    }

    // MARK: - Menu Bar UI Construction

    func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let headerItem = NSMenuItem(title: "ScreenLens — Offline AI Translator", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        let activeTranslateItem = NSMenuItem(title: "Translate Main Content", action: #selector(translateScreen), keyEquivalent: "t")
        activeTranslateItem.keyEquivalentModifierMask = [.option, .command]
        activeTranslateItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(activeTranslateItem)

        let areaTranslateItem = NSMenuItem(title: "Select Area to Translate...", action: #selector(translateSelectedArea), keyEquivalent: "a")
        areaTranslateItem.keyEquivalentModifierMask = [.option, .command]
        areaTranslateItem.image = NSImage(systemSymbolName: "viewfinder.rectangular", accessibilityDescription: nil)
        menu.addItem(areaTranslateItem)

        let wordSelectItem = NSMenuItem(title: "Word Select & Search...", action: #selector(selectAndSearch), keyEquivalent: "s")
        wordSelectItem.keyEquivalentModifierMask = [.option, .command]
        wordSelectItem.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: nil)
        menu.addItem(wordSelectItem)

        let clearItem = NSMenuItem(title: "Clear Translation Overlay", action: #selector(clearOverlayAction), keyEquivalent: "")
        clearItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let langMenu = NSMenu()
        let languages: [(title: String, code: String)] = [
            ("Simplified Chinese (简体中文)", "zh-Hans"),
            ("Traditional Chinese (繁體中文)", "zh-Hant"),
            ("Japanese (日本語)", "ja"),
            ("Korean (한국어)", "ko"),
            ("French (Français)", "fr"),
            ("German (Deutsch)", "de"),
            ("Spanish (Español)", "es"),
            ("English", "en")
        ]
        for lang in languages {
            let item = NSMenuItem(title: lang.title, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.code
            if lang.code == targetLanguage { item.state = .on }
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Target Language", action: nil, keyEquivalent: "")
        langItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        langItem.submenu = langMenu
        menu.addItem(langItem)

        historySubmenu = NSMenu()
        let historyMenuItem = NSMenuItem(title: "Recent Translations", action: nil, keyEquivalent: "")
        historyMenuItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        historyMenuItem.submenu = historySubmenu
        menu.addItem(historyMenuItem)
        refreshHistorySubmenu()

        menu.addItem(.separator())

        axStatusItem = NSMenuItem(title: "Checking Accessibility...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(axStatusItem)

        screenStatusItem = NSMenuItem(title: "Checking Screen Recording...", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        menu.addItem(screenStatusItem)

        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem(title: "Quit ScreenLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastActiveAppPID = front.processIdentifier
        }

        let axTrusted = AXIsProcessTrusted()
        axStatusItem.title = axTrusted ? "Accessibility: Granted (Exact Web/App Content)" : "Accessibility: Grant for Exact Browser Content..."
        axStatusItem.image = NSImage(
            systemSymbolName: axTrusted ? "checkmark.shield.fill" : "shield.lefthalf.filled",
            accessibilityDescription: nil
        )

        let screenTrusted = CGPreflightScreenCaptureAccess()
        screenStatusItem.title = screenTrusted ? "Screen Recording: Granted" : "Screen Recording: Click to Grant..."
        screenStatusItem.image = NSImage(
            systemSymbolName: screenTrusted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )

        launchAtLoginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        refreshHistorySubmenu()
    }

    func refreshHistorySubmenu() {
        historySubmenu.removeAllItems()

        if recentHistory.isEmpty {
            let emptyItem = NSMenuItem(title: "No translations in this session", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            historySubmenu.addItem(emptyItem)
        } else {
            for (idx, item) in recentHistory.prefix(6).enumerated() {
                let preview = item.target.replacingOccurrences(of: "\n", with: " ")
                let truncated = preview.count > 42 ? String(preview.prefix(42)) + "..." : preview
                let menuItem = NSMenuItem(title: "\(idx + 1). \(truncated)", action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                menuItem.representedObject = item.target
                menuItem.toolTip = "Source:\n\(item.source)\n\nTranslation:\n\(item.target)"
                historySubmenu.addItem(menuItem)
            }
        }

        historySubmenu.addItem(.separator())
        historySubmenu.addItem(NSMenuItem(title: "Open Translation_History.md", action: #selector(openHistoryMarkdown), keyEquivalent: ""))
        historySubmenu.addItem(NSMenuItem(title: "Reveal History Folder in Finder", action: #selector(revealHistoryFolder), keyEquivalent: ""))
    }

    // MARK: - Menu Actions

    @objc func setLanguage(_ sender: NSMenuItem) {
        if let lang = sender.representedObject as? String {
            targetLanguage = lang
            UserDefaults.standard.set(lang, forKey: "TargetLanguage")
            if let submenu = sender.menu {
                for item in submenu.items {
                    item.state = (item.representedObject as? String == lang) ? .on : .off
                }
            }
        }
    }

    @objc func clearOverlayAction() {
        dismissTranslation()
    }

    @objc func copyHistoryItem(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            copyToClipboard(text)
        }
    }

    @objc func openHistoryMarkdown() {
        let url = HistoryLogger.shared.markdownFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "# ScreenLens Translation History\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    @objc func revealHistoryFolder() {
        let dir = HistoryLogger.shared.directoryURL
        NSWorkspace.shared.open(dir)
    }

    @objc func openAccessibilitySettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Could not update Launch at Login: \(error.localizedDescription)")
        }
    }

    func setupHotKeys() {
        translateHotKey = HotKey(key: .t, modifiers: [.option, .command])
        translateHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.translateScreen() }
        }

        areaTranslateHotKey = HotKey(key: .a, modifiers: [.option, .command])
        areaTranslateHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.translateSelectedArea() }
        }

        searchHotKey = HotKey(key: .s, modifiers: [.option, .command])
        searchHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.selectAndSearch() }
        }
    }

    @objc func translateScreen() {
        Task { @MainActor in await performTranslate() }
    }

    @objc func translateSelectedArea() {
        Task { @MainActor in startAreaSelectionForTranslation() }
    }

    @objc func selectAndSearch() {
        Task { @MainActor in await performWordSelectSearch() }
    }

    func setStatusLoading(_ loading: Bool) {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: loading ? "ellipsis.circle" : "text.viewfinder",
                accessibilityDescription: "ScreenLens"
            )
        }
    }

    // MARK: - Universal Multi-Screen Coordinate Conversion (Quartz Top-Left <-> AppKit Bottom-Left)

    private func primaryScreenHeight() -> CGFloat {
        // Quartz global origin (0,0) is always anchored at the top-left of the screen at AppKit (0,0)
        return NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 1080
    }

    func quartzToAppKit(_ quartzRect: CGRect) -> CGRect {
        let mainH = primaryScreenHeight()
        return CGRect(
            x: quartzRect.origin.x,
            y: mainH - quartzRect.origin.y - quartzRect.height,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }

    func appKitToQuartz(_ appKitRect: CGRect) -> CGRect {
        let mainH = primaryScreenHeight()
        return CGRect(
            x: appKitRect.origin.x,
            y: mainH - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    func screenContaining(quartzRect: CGRect) -> NSScreen {
        let appKitRect = quartzToAppKit(quartzRect)
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(appKitRect)
            if !inter.isNull {
                let area = inter.width * inter.height
                if area > bestArea {
                    bestArea = area
                    bestScreen = screen
                }
            }
        }
        return bestScreen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func currentMouseScreen() -> NSScreen {
        let mouseLoc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Returns the safe usable AppKit rect for any Mac screen (excluding Menu Bar, Notch, and Dock)
    private func safeUsableAppKitFrame(for screen: NSScreen) -> CGRect {
        var usable = screen.visibleFrame
        let topNotchInset = screen.safeAreaInsets.top
        if topNotchInset > 0 {
            let maxSafeY = screen.frame.maxY - topNotchInset
            if usable.maxY > maxSafeY {
                usable.size.height = max(0, maxSafeY - usable.origin.y)
            }
        }
        return usable
    }

    // MARK: - 1. Translate Active Window Main Content (⌥⌘T)

    func performTranslate() async {
        dismissTranslation()
        closeSelectionWindow()

        // Slight delay if triggered from Menu Bar so the menu closes cleanly before capture
        try? await Task.sleep(nanoseconds: 50_000_000)

        let target = locateActiveMainContentRegion()
        await translateQuartzRegion(target.quartzRect, isMainContentMode: true, targetInfo: target)
    }

    // MARK: - 2. Drag Area to Translate (⌥⌘A)

    func startAreaSelectionForTranslation() {
        dismissTranslation()
        closeSelectionWindow()

        let screen = currentMouseScreen()
        let screenFrame = screen.frame

        let window = FloatingPanel(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.allowsKey = true
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(screenFrame, display: true)

        let view = AreaCaptureView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.onSelectRect = { [weak self] selectedTopLeftRect in
            Task { @MainActor in
                self?.closeSelectionWindow()
                guard let self = self, let rect = selectedTopLeftRect, rect.width > 16, rect.height > 12 else { return }
                let screenQuartz = self.appKitToQuartz(screenFrame)
                let targetQuartz = CGRect(
                    x: screenQuartz.origin.x + rect.origin.x,
                    y: screenQuartz.origin.y + rect.origin.y,
                    width: rect.width,
                    height: rect.height
                )
                try? await Task.sleep(nanoseconds: 60_000_000)
                await self.translateQuartzRegion(targetQuartz, isMainContentMode: false, targetInfo: nil)
            }
        }

        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        selectionWindow = window
    }

    func translateQuartzRegion(
        _ requestedQuartzRegion: CGRect,
        isMainContentMode: Bool,
        targetInfo: ActiveContentTarget?
    ) async {
        setStatusLoading(true)
        defer { setStatusLoading(false) }

        do {
            let (cgImage, actualQuartzRegion) = try await captureRegionImage(requestedQuartzRegion)
            let rawItems = try await performMultiScaleOCR(on: cgImage)
            let mergedParagraphs = mergeIntoParagraphs(rawItems)

            let filtered = mergedParagraphs.filter { item in
                filterContentBlock(
                    item,
                    isMainContentMode: isMainContentMode,
                    targetInfo: targetInfo,
                    regionHeightPts: actualQuartzRegion.height
                )
            }

            guard !filtered.isEmpty else {
                NSSound.beep()
                return
            }

            let blocks = await translateBatch(items: filtered, to: targetLanguage)
            guard !blocks.isEmpty else { return }

            // Draw peripheral blocks first and central blocks last so primary content stays crisp
            let sortedBlocks = blocks.sorted { a, b in
                let aCenter = abs(a.boundingBox.midX - 0.5) + abs(a.boundingBox.midY - 0.5)
                let bCenter = abs(b.boundingBox.midX - 0.5) + abs(b.boundingBox.midY - 0.5)
                return aCenter > bCenter
            }

            let appKitRegion = quartzToAppKit(actualQuartzRegion)
            showTranslationOverlay(blocks: sortedBlocks, appKitRegion: appKitRegion)
            startInputMonitoring()

            let combinedSrc = blocks.map(\.sourceText).joined(separator: "\n")
            let combinedTgt = blocks.map(\.translatedText).joined(separator: "\n")
            recentHistory.insert((source: combinedSrc, target: combinedTgt), at: 0)
            if recentHistory.count > 10 { recentHistory.removeLast() }

            await HistoryLogger.shared.record(blocks: blocks)
        } catch {
            showAlert("Translate failed: \(error.localizedDescription)")
        }
    }

    private func filterContentBlock(
        _ item: TextItem,
        isMainContentMode: Bool,
        targetInfo: ActiveContentTarget?,
        regionHeightPts: CGFloat
    ) -> Bool {
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Manual area selection (⌥⌘A): respect everything the user explicitly dragged over
        if !isMainContentMode {
            return trimmed.count >= 2 || trimmed.containsCJK
        }

        let box = item.boundingBox

        // Drop extreme left/right window border artifacts (scrollbars, resize handles)
        if box.minX < 0.01 || box.maxX > 0.99 { return false }

        // Require minimum meaningful characters (CJK needs fewer chars than Latin)
        if trimmed.containsCJK {
            if trimmed.count < 2 { return false }
        } else {
            if trimmed.count < 3 { return false }
        }

        // Ignore pure numbers/symbols/badges (e.g., "12", "•••", "×")
        if trimmed.range(of: #"^[\d\s\p{P}\p{S}]+$"#, options: .regularExpression) != nil {
            return false
        }

        // Ignore narrow single-line edge navigation/sidebar rails on wide windows
        let isSingleLineHeight = box.height < 0.032
        if isSingleLineHeight && box.width < 0.14 && (box.maxX < 0.16 || box.minX > 0.84) {
            return false
        }

        // If AXWebArea / AXScrollArea wasn't available, filter residual top browser/toolbar chrome
        let exactAX = targetInfo?.isExactContentArea ?? false
        let isBrowser = targetInfo?.isBrowserWindow ?? false

        if !exactAX {
            let distFromTopPts = (1.0 - box.maxY) * regionHeightPts

            // Filter URL bar strings near the top edge
            if distFromTopPts < 110 {
                let urlRegex = #"^(https?://|www\.|localhost(:\d+)?|[a-zA-Z0-9-]+(\.[a-zA-Z]{2,})+(/.*)?)$"#
                if trimmed.range(of: urlRegex, options: .regularExpression) != nil {
                    return false
                }
            }

            // Filter narrow single-line browser tab titles / bookmark items in the top chrome strip
            if isBrowser && distFromTopPts < 88 && box.width < 0.28 && box.height < 0.032 {
                return false
            }
        }

        return true
    }

    func showTranslationOverlay(blocks: [TranslatedBlock], appKitRegion: CGRect) {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil

        let window = FloatingPanel(
            contentRect: appKitRegion,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window.allowsKey = false
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        let view = TranslationOverlayView(frame: NSRect(origin: .zero, size: appKitRegion.size))
        view.blocks = blocks
        window.contentView = view
        window.setFrame(appKitRegion, display: true)
        window.orderFrontRegardless()
        overlayWindow = window
    }

    func startInputMonitoring() {
        isTranslating = true
        stopInputMonitors()

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .keyDown
        ]

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in
                self?.dismissTranslation()
            }
        }) {
            inputMonitors.append(monitor)
        }
    }

    func stopInputMonitors() {
        for monitor in inputMonitors {
            NSEvent.removeMonitor(monitor)
        }
        inputMonitors.removeAll()
    }

    func dismissTranslation() {
        guard isTranslating || overlayWindow != nil else { return }
        isTranslating = false
        stopInputMonitors()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    func closeSelectionWindow() {
        guard selectionWindow != nil else { return }
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        if let pid = lastActiveAppPID,
           let prevApp = NSRunningApplication(processIdentifier: pid) {
            prevApp.activate()
        }
    }

    // MARK: - 3. Word Select & Search (⌥⌘S)

    func performWordSelectSearch() async {
        dismissTranslation()
        closeSelectionWindow()

        let screen = currentMouseScreen()
        let screenFrame = screen.frame

        setStatusLoading(true)
        defer { setStatusLoading(false) }

        do {
            let quartzScreenRect = appKitToQuartz(screenFrame)
            let (cgImage, actualQuartzRect) = try await captureRegionImage(quartzScreenRect)
            let words = try await extractWordsMultiScale(from: cgImage)

            guard !words.isEmpty else {
                NSSound.beep()
                return
            }

            let actualAppKitFrame = quartzToAppKit(actualQuartzRect)
            let topSafeInset = max(screen.safeAreaInsets.top, 0)
            showWordSelectionOverlay(words: words, screenFrame: actualAppKitFrame, topSafeInset: topSafeInset)
        } catch {
            showAlert("Failed to start word selection: \(error.localizedDescription)")
        }
    }

    func showWordSelectionOverlay(words: [WordBox], screenFrame: CGRect, topSafeInset: CGFloat) {
        closeSelectionWindow()

        let window = FloatingPanel(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.allowsKey = true
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        let view = WordSelectionView(
            words: words,
            frame: NSRect(origin: .zero, size: screenFrame.size),
            topSafeInset: topSafeInset
        )
        view.onComplete = { [weak self] selectedText in
            Task { @MainActor in
                self?.closeSelectionWindow()
                if let text = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    self?.copyToClipboard(text)
                    self?.openGoogleSearch(query: text)
                }
            }
        }
        view.onCancel = { [weak self] in
            Task { @MainActor in
                self?.closeSelectionWindow()
            }
        }

        window.contentView = view
        window.setFrame(screenFrame, display: true)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        selectionWindow = window
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openGoogleSearch(query: String) {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Main-Content Region Locator (Ignores Menu Bar, Tabs, Bookmarks, URL Bar)

    func locateActiveMainContentRegion() -> ActiveContentTarget {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        let effectivePID: pid_t? = (frontApp != nil && frontApp?.processIdentifier != ownPID)
            ? frontApp?.processIdentifier
            : lastActiveAppPID

        let targetApp = effectivePID.flatMap { NSRunningApplication(processIdentifier: $0) }
        let bundleID = targetApp?.bundleIdentifier ?? ""
        let isBrowser = browserBundleIDs.contains(bundleID)

        // 1. Accessibility Lookup: Exact AXWebArea (browsers) or primary AXScrollArea (document apps)
        if let pid = effectivePID, pid != ownPID, AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, true as CFBoolean)
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFBoolean)

            if let windowElement = focusedOrMainWindow(for: appElement),
               let windowRect = frameOfAXElement(windowElement),
               windowRect.width > 120, windowRect.height > 100 {

                let screen = screenContaining(quartzRect: windowRect)
                let usableQuartz = appKitToQuartz(safeUsableAppKitFrame(for: screen))
                let clampedWindow = windowRect.intersection(usableQuartz)

                // A. Try AXWebArea first (automatically excludes macOS menu bar, tabs, URL bar, and bookmarks bar)
                if let webArea = findLargestElement(
                    matchingRoles: ["AXWebArea"],
                    root: windowElement,
                    within: clampedWindow,
                    maxDepth: 14
                ), let webRect = frameOfAXElement(webArea) {
                    let exact = webRect.intersection(clampedWindow)
                    if exact.width > 120 && exact.height > 100 {
                        return ActiveContentTarget(
                            quartzRect: exact,
                            isExactContentArea: true,
                            isBrowserWindow: isBrowser
                        )
                    }
                }

                // B. For native document/reader apps (Preview, Notes, Pages, Mail), try primary AXScrollArea
                if !isBrowser,
                   let scrollArea = findLargestElement(
                    matchingRoles: ["AXScrollArea"],
                    root: windowElement,
                    within: clampedWindow,
                    maxDepth: 8
                   ),
                   let scrollRect = frameOfAXElement(scrollArea) {
                    let exact = scrollRect.intersection(clampedWindow)
                    if exact.width >= clampedWindow.width * 0.55 && exact.height >= clampedWindow.height * 0.55 {
                        return ActiveContentTarget(
                            quartzRect: exact,
                            isExactContentArea: true,
                            isBrowserWindow: false
                        )
                    }
                }

                // C. Window found via AX, but no AXWebArea exposed -> trim top chrome proportionally
                let trimmed = trimWindowChrome(
                    windowQuartzRect: clampedWindow,
                    isBrowser: isBrowser,
                    bundleID: bundleID
                )
                return ActiveContentTarget(
                    quartzRect: trimmed,
                    isExactContentArea: false,
                    isBrowserWindow: isBrowser
                )
            }
        }

        // 2. WindowServer Fallback (CGWindowListCopyWindowInfo)
        if let rawWindowRect = findWindowServerRect(targetPID: effectivePID, ownPID: ownPID) {
            let screen = screenContaining(quartzRect: rawWindowRect)
            let usableQuartz = appKitToQuartz(safeUsableAppKitFrame(for: screen))
            let clampedWindow = rawWindowRect.intersection(usableQuartz)

            if !clampedWindow.isNull && clampedWindow.width > 120 && clampedWindow.height > 100 {
                let trimmed = trimWindowChrome(
                    windowQuartzRect: clampedWindow,
                    isBrowser: isBrowser,
                    bundleID: bundleID
                )
                return ActiveContentTarget(
                    quartzRect: trimmed,
                    isExactContentArea: false,
                    isBrowserWindow: isBrowser
                )
            }
        }

        // 3. Ultimate Fallback: Active screen's safe usable frame (excludes Menu Bar, Notch & Dock)
        let screen = currentMouseScreen()
        let usableQuartz = appKitToQuartz(safeUsableAppKitFrame(for: screen))
        return ActiveContentTarget(
            quartzRect: usableQuartz,
            isExactContentArea: false,
            isBrowserWindow: isBrowser
        )
    }

    private func trimWindowChrome(windowQuartzRect: CGRect, isBrowser: Bool, bundleID: String) -> CGRect {
        // Covers title/tab bar (~40pt) + address/URL bar (~42pt) + bookmarks bar (~32pt)
        var topInset: CGFloat = isBrowser ? 114.0 : 52.0
        var leftInset: CGFloat = 0.0

        // Arc uses a left sidebar + slim top URL bar rather than tall top tabs + bookmarks
        if bundleID == "company.thebrowser.Browser" {
            topInset = 24.0
            if windowQuartzRect.width > 920 {
                leftInset = 215.0
            }
        }

        // Never trim more than 24% of the window height on compact windows
        topInset = min(topInset, windowQuartzRect.height * 0.24)

        return CGRect(
            x: windowQuartzRect.origin.x + leftInset,
            y: windowQuartzRect.origin.y + topInset,
            width: max(windowQuartzRect.width - leftInset, 100),
            height: max(windowQuartzRect.height - topInset, 80)
        )
    }

    private func focusedOrMainWindow(for appElement: AXUIElement) -> AXUIElement? {
        var windowObj: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObj) != .success {
            if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowObj) != .success {
                var windowsList: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsList) == .success,
                   let windows = windowsList as? [AXUIElement],
                   let firstWin = windows.first {
                    windowObj = firstWin
                }
            }
        }
        guard let obj = windowObj, CFGetTypeID(obj) == AXUIElementGetTypeID() else { return nil }
        return (obj as! AXUIElement)
    }

    private func findLargestElement(
        matchingRoles targetRoles: Set<String>,
        root: AXUIElement,
        within bounds: CGRect,
        maxDepth: Int
    ) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var bestElement: AXUIElement?
        var bestArea: CGFloat = 0

        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()

            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String,
               targetRoles.contains(role),
               let rect = frameOfAXElement(current) {
                let clipped = rect.intersection(bounds)
                if !clipped.isNull {
                    let area = clipped.width * clipped.height
                    if area > bestArea {
                        bestArea = area
                        bestElement = current
                    }
                }
            }

            if depth < maxDepth {
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                   let children = childrenRef as? [AXUIElement] {
                    for child in children {
                        queue.append((child, depth + 1))
                    }
                }
            }
        }

        return bestElement
    }

    private func frameOfAXElement(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private func findWindowServerRect(targetPID: pid_t?, ownPID: pid_t) -> CGRect? {
        let ignoredOwners: Set<String> = [
            "Window Server", "WindowServer", "Dock", "Control Center",
            "SystemUIServer", "Notification Center", "Wallpaper"
        ]

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var topmostAnyAppRect: CGRect?

        for info in windowInfoList {
            guard let ownerPIDNumber = info["kCGWindowOwnerPID"] as? NSNumber else { continue }
            let ownerPID = ownerPIDNumber.int32Value
            guard ownerPID != ownPID else { continue }

            if let ownerName = info["kCGWindowOwnerName"] as? String, ignoredOwners.contains(ownerName) {
                continue
            }

            let layer = (info["kCGWindowLayer"] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }

            let alpha = (info["kCGWindowAlpha"] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.05 else { continue }

            guard let boundsObj = info["kCGWindowBounds"] else { continue }
            let boundsCF = boundsObj as CFTypeRef
            guard CFGetTypeID(boundsCF) == CFDictionaryGetTypeID(),
                  let rect = CGRect(dictionaryRepresentation: (boundsCF as! CFDictionary)),
                  rect.width > 120, rect.height > 80 else {
                continue
            }

            if topmostAnyAppRect == nil {
                topmostAnyAppRect = rect
            }

            if let pid = targetPID, ownerPID == pid {
                return rect
            }
        }

        return topmostAnyAppRect
    }

    // MARK: - 1:1 Clamped Screen Capture

    func captureRegionImage(_ quartzRect: CGRect) async throws -> (CGImage, CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(quartzRect) }) ?? content.displays.first else {
            throw NSError(domain: "ScreenLens", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let clampedQuartz = quartzRect.intersection(display.frame).integral
        guard clampedQuartz.width > 32, clampedQuartz.height > 32 else {
            throw NSError(domain: "ScreenLens", code: 3, userInfo: [NSLocalizedDescriptionKey: "Capture region outside screen bounds"])
        }

        let screen = screenContaining(quartzRect: clampedQuartz)
        let scale = screen.backingScaleFactor

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()

        let localRect = CGRect(
            x: clampedQuartz.origin.x - display.frame.origin.x,
            y: clampedQuartz.origin.y - display.frame.origin.y,
            width: clampedQuartz.width,
            height: clampedQuartz.height
        )
        config.sourceRect = localRect
        config.width = Int(localRect.width * scale)
        config.height = Int(localRect.height * scale)
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, clampedQuartz)
    }

    // MARK: - Best-Model Multi-Scale Vision OCR (Tiny Footnotes + Oversized Headlines)

    nonisolated private static func configureBestTextRequest(_ request: VNRecognizeTextRequest, minimumTextHeight: Float) {
        if let latestRevision = VNRecognizeTextRequest.supportedRevisions.max() {
            request.revision = latestRevision
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = minimumTextHeight
    }

    nonisolated func performMultiScaleOCR(on cgImage: CGImage) async throws -> [TextItem] {
        var combined: [TextItem] = []

        // Pass 1: High-sensitivity pass for small & medium body text
        let maxDim = max(cgImage.width, cgImage.height)
        let smallUpscale: CGFloat = maxDim < 1800 ? 1.5 : 1.15
        let pass1Image = Self.resizeCGImage(cgImage, scale: smallUpscale) ?? cgImage
        let pass1Items = try await runSingleTextPass(on: pass1Image, minimumTextHeight: 0.0035)
        combined.append(contentsOf: pass1Items)

        // Pass 2: Downscaled pass on large captures so oversized display headings don't fragment
        if maxDim > 1600 {
            let downscale = 1400.0 / CGFloat(maxDim)
            if let pass2Image = Self.resizeCGImage(cgImage, scale: downscale) {
                let pass2Items = try await runSingleTextPass(on: pass2Image, minimumTextHeight: 0.024)
                combined.append(contentsOf: pass2Items)
            }
        }

        return deduplicateTextItems(combined, iouThreshold: 0.55)
    }

    nonisolated private func runSingleTextPass(on cgImage: CGImage, minimumTextHeight: Float) async throws -> [TextItem] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let items: [TextItem] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TextItem(
                        text: text,
                        boundingBox: obs.boundingBox,
                        avgLineHeight: obs.boundingBox.height,
                        confidence: candidate.confidence
                    )
                }
                continuation.resume(returning: items)
            }
            Self.configureBestTextRequest(request, minimumTextHeight: minimumTextHeight)

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private func deduplicateTextItems(_ items: [TextItem], iouThreshold: CGFloat) -> [TextItem] {
        let sorted = items.sorted {
            if abs($0.confidence - $1.confidence) > 0.08 {
                return $0.confidence > $1.confidence
            }
            return $0.text.count > $1.text.count
        }
        var kept: [TextItem] = []
        for item in sorted {
            let dup = kept.contains { existing in
                Self.iou(existing.boundingBox, item.boundingBox) > iouThreshold
            }
            if !dup {
                kept.append(item)
            }
        }
        return kept
    }

    // MARK: - Multi-Scale Word Extraction for Select & Search (⌥⌘S)

    nonisolated func extractWordsMultiScale(from cgImage: CGImage) async throws -> [WordBox] {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let maxDim = max(width, height)
        var allWords: [WordBox] = []

        // Pass 1A: Ultra-macro pass so giant hero banners (100pt-240pt) are detected as whole words
        if maxDim > 1400 {
            let ultraMacroScale = 1100.0 / maxDim
            if let ultraMacroImage = Self.resizeCGImage(cgImage, scale: ultraMacroScale) {
                let heroWords = try await extractWordsFromTile(
                    tileImage: ultraMacroImage,
                    tileNormRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                    minimumTextHeight: 0.035
                )
                allWords.append(contentsOf: heroWords)
            }
        }

        // Pass 1B: Standard full-screen pass for medium/large headings & body text
        let macroScale: CGFloat = maxDim > 2200 ? (1900.0 / maxDim) : 1.0
        let macroImage = Self.resizeCGImage(cgImage, scale: macroScale) ?? cgImage
        let macroWords = try await extractWordsFromTile(
            tileImage: macroImage,
            tileNormRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            minimumTextHeight: 0.011
        )
        allWords.append(contentsOf: macroWords)

        // Pass 2: Overlapping 2x2 upscaled grid so tiny 6pt-11pt text on any screen size is detected cleanly
        let overlap: CGFloat = 0.08
        let quadrantsTopLeft: [CGRect] = [
            CGRect(x: 0, y: 0, width: width * (0.5 + overlap), height: height * (0.5 + overlap)),
            CGRect(x: width * (0.5 - overlap), y: 0, width: width * (0.5 + overlap), height: height * (0.5 + overlap)),
            CGRect(x: 0, y: height * (0.5 - overlap), width: width * (0.5 + overlap), height: height * (0.5 + overlap)),
            CGRect(x: width * (0.5 - overlap), y: height * (0.5 - overlap), width: width * (0.5 + overlap), height: height * (0.5 + overlap))
        ]

        let microUpscale: CGFloat = maxDim >= 3200 ? 1.5 : 2.0

        for pixelCrop in quadrantsTopLeft {
            let integralCrop = pixelCrop.integral
            guard let cropped = cgImage.cropping(to: integralCrop) else { continue }

            let normX = integralCrop.origin.x / width
            let normW = integralCrop.width / width
            let normH = integralCrop.height / height
            let normY = 1.0 - ((integralCrop.origin.y + integralCrop.height) / height)
            let tileNormRect = CGRect(x: normX, y: normY, width: normW, height: normH)

            let upscaledTile = Self.resizeCGImage(cropped, scale: microUpscale) ?? cropped
            let tileWords = try await extractWordsFromTile(
                tileImage: upscaledTile,
                tileNormRect: tileNormRect,
                minimumTextHeight: 0.003
            )
            allWords.append(contentsOf: tileWords)
        }

        // Deduplicate overlapping words across macro + 2x2 micro passes
        let sortedByConf = allWords.sorted {
            if abs($0.confidence - $1.confidence) > 0.08 {
                return $0.confidence > $1.confidence
            }
            return $0.word.count > $1.word.count
        }
        var uniqueWords: [WordBox] = []
        for candidate in sortedByConf {
            let isDup = uniqueWords.contains { existing in
                Self.iou(existing.rect, candidate.rect) > 0.45
            }
            if !isDup {
                uniqueWords.append(candidate)
            }
        }

        // Sort in natural reading order (top-to-bottom, left-to-right)
        return uniqueWords.sorted { a, b in
            let verticalDiff = a.rect.maxY - b.rect.maxY
            if abs(verticalDiff) > min(a.rect.height, b.rect.height) * 0.45 {
                return a.rect.maxY > b.rect.maxY
            }
            return a.rect.minX < b.rect.minX
        }
    }

    nonisolated private func extractWordsFromTile(
        tileImage: CGImage,
        tileNormRect: CGRect,
        minimumTextHeight: Float
    ) async throws -> [WordBox] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                var rawWords: [WordBox] = []
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let tokenizer = NLTokenizer(unit: .word)

                for obs in observations {
                    guard let recognized = obs.topCandidates(1).first else { continue }
                    let full = recognized.string
                    let totalCount = max(full.count, 1)
                    let lineBox = obs.boundingBox

                    // Use NLTokenizer so both space-delimited (English) and continuous (CJK) scripts segment into true words
                    tokenizer.string = full
                    var tokenRanges: [Range<String.Index>] = []
                    tokenizer.enumerateTokens(in: full.startIndex..<full.endIndex) { range, _ in
                        tokenRanges.append(range)
                        return true
                    }

                    // Fallback to whitespace splitting if NLTokenizer yields no word tokens (e.g., pure symbols/codes)
                    if tokenRanges.isEmpty {
                        var searchStart = full.startIndex
                        while searchStart < full.endIndex {
                            while searchStart < full.endIndex && full[searchStart].isWhitespace {
                                searchStart = full.index(after: searchStart)
                            }
                            if searchStart >= full.endIndex { break }
                            var wordEnd = searchStart
                            while wordEnd < full.endIndex && !full[wordEnd].isWhitespace {
                                wordEnd = full.index(after: wordEnd)
                            }
                            tokenRanges.append(searchStart..<wordEnd)
                            searchStart = wordEnd
                        }
                    }

                    for range in tokenRanges {
                        let word = String(full[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !word.isEmpty else { continue }

                        let localBox: CGRect
                        if let box = try? recognized.boundingBox(for: range),
                           box.boundingBox.width > 0.0005, box.boundingBox.height > 0.0005 {
                            localBox = box.boundingBox
                        } else {
                            let startOffset = CGFloat(full.distance(from: full.startIndex, to: range.lowerBound)) / CGFloat(totalCount)
                            let endOffset = CGFloat(full.distance(from: full.startIndex, to: range.upperBound)) / CGFloat(totalCount)
                            localBox = CGRect(
                                x: lineBox.origin.x + lineBox.width * startOffset,
                                y: lineBox.origin.y,
                                width: max(lineBox.width * (endOffset - startOffset), 0.004),
                                height: lineBox.height
                            )
                        }

                        let globalBox = CGRect(
                            x: tileNormRect.origin.x + localBox.origin.x * tileNormRect.width,
                            y: tileNormRect.origin.y + localBox.origin.y * tileNormRect.height,
                            width: localBox.width * tileNormRect.width,
                            height: localBox.height * tileNormRect.height
                        )
                        rawWords.append(WordBox(word: word, rect: globalBox, confidence: recognized.confidence))
                    }
                }
                continuation.resume(returning: rawWords)
            }
            Self.configureBestTextRequest(request, minimumTextHeight: minimumTextHeight)

            let handler = VNImageRequestHandler(cgImage: tileImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private static func resizeCGImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
        guard abs(scale - 1.0) > 0.02 else { return image }
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }
        return sharedCIContext.createCGImage(output, from: output.extent)
    }

    nonisolated private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = (a.width * a.height) + (b.width * b.height) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    // MARK: - Column-Aware Paragraph Clustering

    nonisolated func mergeIntoParagraphs(_ items: [TextItem]) -> [TextItem] {
        guard items.count > 1 else { return items }

        let sorted = items.sorted { a, b in
            let dy = a.boundingBox.maxY - b.boundingBox.maxY
            if abs(dy) > min(a.boundingBox.height, b.boundingBox.height) * 0.5 {
                return a.boundingBox.maxY > b.boundingBox.maxY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        struct Para {
            var text: String
            var unionBox: CGRect
            var lastBox: CGRect
            var firstMinX: CGFloat
            var avgH: CGFloat
            var avgConf: Float
            var count: Int
        }

        var paras: [Para] = []

        for item in sorted {
            let box = item.boundingBox
            var joined = false

            if let idx = paras.indices.last {
                let p = paras[idx]

                // Same-line horizontal continuation
                let overlapY = min(p.lastBox.maxY, box.maxY) - max(p.lastBox.minY, box.minY)
                let minH = min(p.lastBox.height, box.height)
                let gapX = box.minX - p.lastBox.maxX
                if overlapY > minH * 0.35 && gapX >= -0.03 && gapX < p.avgH * 3.0 {
                    var cur = p
                    cur.text = joinTextLines(cur.text, item.text)
                    cur.unionBox = cur.unionBox.union(box)
                    cur.lastBox = box
                    cur.avgH = (cur.avgH * CGFloat(cur.count) + box.height) / CGFloat(cur.count + 1)
                    cur.avgConf = (cur.avgConf * Float(cur.count) + item.confidence) / Float(cur.count + 1)
                    cur.count += 1
                    paras[idx] = cur
                    joined = true
                }

                // Vertical continuation in the same column
                if !joined {
                    let gapY = p.lastBox.minY - box.maxY
                    let sameColumn = abs(box.minX - p.firstMinX) < 0.15 || abs(box.minX - p.lastBox.minX) < 0.15
                    let closeEnough = gapY >= -p.avgH * 0.4 && gapY <= p.avgH * 1.6
                    let similarSize = box.height / max(p.avgH, 0.001) > 0.55 && box.height / max(p.avgH, 0.001) < 1.85

                    let endsSentence = [".", "!", "?", "。", "！", "？"].contains(p.text.last ?? " ")
                    let shortEnd = p.lastBox.width < p.unionBox.width * 0.5
                    let clearBreak = endsSentence && shortEnd && gapY > p.avgH * 0.8

                    if sameColumn && closeEnough && similarSize && !clearBreak {
                        var cur = p
                        cur.text = joinTextLines(cur.text, item.text)
                        cur.unionBox = cur.unionBox.union(box)
                        cur.lastBox = box
                        cur.avgH = (cur.avgH * CGFloat(cur.count) + box.height) / CGFloat(cur.count + 1)
                        cur.avgConf = (cur.avgConf * Float(cur.count) + item.confidence) / Float(cur.count + 1)
                        cur.count += 1
                        paras[idx] = cur
                        joined = true
                    }
                }
            }

            if !joined {
                paras.append(Para(
                    text: item.text,
                    unionBox: box,
                    lastBox: box,
                    firstMinX: box.minX,
                    avgH: box.height,
                    avgConf: item.confidence,
                    count: 1
                ))
            }
        }

        return paras.map {
            TextItem(text: $0.text, boundingBox: $0.unionBox, avgLineHeight: $0.avgH, confidence: $0.avgConf)
        }
    }

    nonisolated private func joinTextLines(_ first: String, _ second: String) -> String {
        if first.hasSuffix("-") && first.count > 1 {
            return String(first.dropLast()) + second
        }
        if let lastChar = first.unicodeScalars.last,
           let nextChar = second.unicodeScalars.first {
            let isLastCJK = (0x4E00...0x9FFF).contains(lastChar.value) || (0x3040...0x30FF).contains(lastChar.value)
            let isNextCJK = (0x4E00...0x9FFF).contains(nextChar.value) || (0x3040...0x30FF).contains(nextChar.value)
            if isLastCJK && isNextCJK {
                return first + second
            }
        }
        return first + " " + second
    }

    // MARK: - Auto-Detected Neural Batch Translation

    nonisolated private static func detectLanguage(for text: String) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let dominant = recognizer.dominantLanguage, dominant != .undetermined {
            return Locale.Language(identifier: dominant.rawValue)
        }
        return Locale.Language(identifier: "en")
    }

    nonisolated func translateBatch(items: [TextItem], to target: String) async -> [TranslatedBlock] {
        let targetLang = Locale.Language(identifier: target)

        if #available(macOS 26.0, *) {
            // Group items by detected source language so multilingual pages translate accurately
            var groupedIndices: [String: (source: Locale.Language, indices: [Int])] = [:]
            var translatedByIndex: [Int: String] = [:]

            for (idx, item) in items.enumerated() {
                let detected = Self.detectLanguage(for: item.text)
                // Skip blocks already in the exact target language/script
                if detected.minimalIdentifier == targetLang.minimalIdentifier {
                    translatedByIndex[idx] = item.text
                    continue
                }
                let key = detected.minimalIdentifier
                if var existing = groupedIndices[key] {
                    existing.indices.append(idx)
                    groupedIndices[key] = existing
                } else {
                    groupedIndices[key] = (source: detected, indices: [idx])
                }
            }

            for (_, group) in groupedIndices {
                let session = TranslationSession(installedSource: group.source, target: targetLang)
                let requests = group.indices.map { idx in
                    TranslationSession.Request(sourceText: items[idx].text, clientIdentifier: "\(idx)")
                }
                if let responses = try? await session.translations(from: requests) {
                    for response in responses {
                        if let idStr = response.clientIdentifier, let idx = Int(idStr), idx < items.count {
                            translatedByIndex[idx] = response.targetText
                        }
                    }
                }
            }

            if !translatedByIndex.isEmpty {
                return items.enumerated().map { idx, item in
                    TranslatedBlock(
                        sourceText: item.text,
                        translatedText: translatedByIndex[idx] ?? item.text,
                        boundingBox: item.boundingBox,
                        avgLineHeight: item.avgLineHeight
                    )
                }
            }
        }

        return items.map {
            TranslatedBlock(sourceText: $0.text, translatedText: $0.text, boundingBox: $0.boundingBox, avgLineHeight: $0.avgLineHeight)
        }
    }

    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ScreenLens"
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - String Helpers

private extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value) ||
            (0x3040...0x30FF).contains(scalar.value) ||
            (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}

// MARK: - History Logger

actor HistoryLogger {
    static let shared = HistoryLogger()
    nonisolated let directoryURL: URL
    nonisolated let markdownFileURL: URL
    private var lastHash: Int = 0

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ScreenLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directoryURL = dir
        self.markdownFileURL = dir.appendingPathComponent("Translation_History.md")
    }

    func record(blocks: [TranslatedBlock]) {
        guard !blocks.isEmpty else { return }
        let combinedSource = blocks.map(\.sourceText).joined(separator: "\n\n")
        let combinedTarget = blocks.map(\.translatedText).joined(separator: "\n\n")
        let hash = combinedSource.hashValue ^ combinedTarget.hashValue
        guard hash != lastHash else { return }
        lastHash = hash

        let now = ISO8601DateFormatter().string(from: Date())
        let entry = """

        ## \(now)
        **Source:**
        > \(combinedSource.replacingOccurrences(of: "\n", with: "\n> "))

        **Translation:**
        \(combinedTarget)

        ---
        """
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: markdownFileURL.path),
               let handle = try? FileHandle(forWritingTo: markdownFileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: markdownFileURL, options: .atomic)
            }
        }
    }
}

// MARK: - Interactive Area Capture View (⌥⌘A, Top-Left Flipped)

class AreaCaptureView: NSView {
    var onSelectRect: ((CGRect?) -> Void)?
    private var startPoint: NSPoint?
    private var currentRect: CGRect?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        if let rect = currentRect {
            NSColor.clear.setFill()
            rect.fill(using: .copy)

            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.systemCyan.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let finalRect = currentRect
        startPoint = nil
        currentRect = nil
        onSelectRect?(finalRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onSelectRect?(nil)
        }
    }
}

// MARK: - Inline Screen-Scaling Translation Overlay View (Top-Left Flipped)

class TranslationOverlayView: NSView {
    var blocks: [TranslatedBlock] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let screenMinFont = max(6.0, bounds.height * 0.007)
        let screenMaxFont = min(max(bounds.height * 0.085, 24.0), 72.0)

        for block in blocks {
            var coverRect = convertVisionToFlippedView(block.boundingBox).intersection(bounds)
            guard !coverRect.isNull, coverRect.width >= 8, coverRect.height >= 8 else { continue }

            let originalLineHeightPts = max(block.avgLineHeight * bounds.height, 6.0)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = max(1.0, min(originalLineHeightPts * 0.08, 3.0))

            let padX = min(max(coverRect.width * 0.015, 3.0), 8.0)
            let padY = min(max(coverRect.height * 0.04, 1.5), 5.0)
            var drawRect = coverRect.insetBy(dx: padX, dy: padY)
            guard drawRect.width > 4, drawRect.height > 4 else { continue }

            let (fontSize, requiredHeight) = optimalFontSize(
                for: block.translatedText,
                in: drawRect.size,
                originalLineHeight: originalLineHeightPts,
                minFont: screenMinFont,
                maxCap: screenMaxFont,
                paragraphStyle: paragraph
            )

            // Expand coverRect modestly (up to +18% / +14pt) if translated text is longer than source
            if requiredHeight > drawRect.height {
                let extraNeeded = min(requiredHeight - drawRect.height, max(coverRect.height * 0.18, 14.0))
                let expanded = CGRect(
                    x: coverRect.origin.x,
                    y: coverRect.origin.y,
                    width: coverRect.width,
                    height: coverRect.height + extraNeeded
                ).intersection(bounds)
                if !expanded.isNull {
                    coverRect = expanded
                    drawRect = coverRect.insetBy(dx: padX, dy: padY)
                }
            }

            let cornerRadius = min(max(originalLineHeightPts * 0.25, 4.0), 10.0)
            let path = NSBezierPath(roundedRect: coverRect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
            path.fill()

            NSColor.white.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 1.0
            path.stroke()

            let weight: NSFont.Weight = originalLineHeightPts >= 22.0 ? .semibold : .medium
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]

            let attrStr = NSAttributedString(string: block.translatedText, attributes: attrs)
            attrStr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    private func optimalFontSize(
        for text: String,
        in targetSize: NSSize,
        originalLineHeight: CGFloat,
        minFont: CGFloat,
        maxCap: CGFloat,
        paragraphStyle: NSParagraphStyle
    ) -> (size: CGFloat, height: CGFloat) {
        let upper = min(max(originalLineHeight * 0.92, minFont), maxCap)
        var low = minFont
        var high = upper
        var bestSize = minFont
        var bestHeight: CGFloat = 0

        let measureWidth = max(targetSize.width, 24)
        for _ in 0..<10 {
            let mid = (low + high) * 0.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: mid, weight: .medium),
                .paragraphStyle: paragraphStyle
            ]
            let bound = (text as NSString).boundingRect(
                with: NSSize(width: measureWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            if bound.height <= targetSize.height + 2.5 {
                bestSize = mid
                bestHeight = bound.height
                low = mid
            } else {
                high = mid
            }
        }

        if bestHeight == 0 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: minFont, weight: .medium),
                .paragraphStyle: paragraphStyle
            ]
            bestHeight = (text as NSString).boundingRect(
                with: NSSize(width: measureWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            ).height
        }

        return (bestSize, bestHeight)
    }

    private func convertVisionToFlippedView(_ normalized: CGRect) -> CGRect {
        let x = normalized.origin.x * bounds.width
        let y = (1.0 - normalized.maxY) * bounds.height
        let w = normalized.size.width * bounds.width
        let h = normalized.size.height * bounds.height
        return CGRect(x: x, y: y, width: max(w, 14), height: max(h, 10))
    }
}

// MARK: - Word Selection & Rubber-Band Marquee Search View (⌥⌘S, Top-Left Flipped)

class WordSelectionView: NSView {
    let words: [WordBox]
    let topSafeInset: CGFloat
    var onComplete: ((String?) -> Void)?
    var onCancel: (() -> Void)?

    private var selectedIndices: Set<Int> = []
    private var hoveredIndex: Int?
    private var dragStartPoint: NSPoint?
    private var dragCurrentPoint: NSPoint?
    private var anchorWordIndex: Int?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(words: [WordBox], frame: NSRect, topSafeInset: CGFloat = 0) {
        self.words = words
        self.topSafeInset = topSafeInset
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        for (i, word) in words.enumerated() {
            let rect = convertVisionToFlippedView(word.rect).insetBy(dx: -2, dy: -1)
            let corner = min(max(rect.height * 0.2, 3.0), 6.0)
            let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

            if selectedIndices.contains(i) {
                NSColor.systemBlue.withAlphaComponent(0.65).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.85).setStroke()
                path.lineWidth = 1.0
                path.stroke()
            } else if hoveredIndex == i {
                NSColor.systemCyan.withAlphaComponent(0.35).setFill()
                path.fill()
                NSColor.systemCyan.setStroke()
                path.lineWidth = 1.2
                path.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.18).setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }
        }

        if let start = dragStartPoint, let current = dragCurrentPoint {
            let marquee = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            if marquee.width > 4 || marquee.height > 4 {
                NSColor.systemCyan.withAlphaComponent(0.15).setFill()
                marquee.fill()
                let border = NSBezierPath(roundedRect: marquee, xRadius: 4, yRadius: 4)
                NSColor.systemCyan.setStroke()
                border.lineWidth = 1.5
                border.stroke()
            }
        }

        let selectedText = selectedIndices.sorted().map { words[$0].word }.joined(separator: " ")
        let bannerText = selectedText.isEmpty
            ? "Click any word or drag a box across words to copy & Google Search (Press Esc to cancel)"
            : "Search: \"\(selectedText)\""

        let bannerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (bannerText as NSString).size(withAttributes: bannerAttrs)
        let pillWidth = min(max(textSize.width + 32, 320), bounds.width - 40)
        // Clear both the macOS menu bar and any MacBook notch safeAreaInset
        let pillY = max(44.0, topSafeInset + 14.0)
        let pillRect = CGRect(x: (bounds.width - pillWidth) / 2, y: pillY, width: pillWidth, height: 34)

        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 17, yRadius: 17)
        NSColor(calibratedWhite: 0.1, alpha: 0.90).setFill()
        pillPath.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        pillPath.stroke()

        let textRect = CGRect(
            x: pillRect.origin.x + 16,
            y: pillRect.origin.y + (pillRect.height - textSize.height) / 2,
            width: pillRect.width - 32,
            height: textSize.height
        )
        (bannerText as NSString).draw(in: textRect, withAttributes: bannerAttrs)
    }

    private func convertVisionToFlippedView(_ normalized: CGRect) -> CGRect {
        let x = normalized.origin.x * bounds.width
        let y = (1.0 - normalized.maxY) * bounds.height
        let w = normalized.size.width * bounds.width
        let h = normalized.size.height * bounds.height
        return CGRect(x: x, y: y, width: max(w, 8), height: max(h, 8))
    }

    private func indexOfWord(at point: NSPoint) -> Int? {
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for (i, word) in words.enumerated() {
            let rect = convertVisionToFlippedView(word.rect)
            // Generous hit padding so tiny 6pt-10pt words are easy to click on any screen
            let hitRect = rect.insetBy(dx: -6, dy: -4)
            if hitRect.contains(point) {
                let dist = hypot(rect.midX - point.x, rect.midY - point.y)
                if dist < bestDistance {
                    bestDistance = dist
                    bestIndex = i
                }
            }
        }
        return bestIndex
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHover = indexOfWord(at: point)
        if newHover != hoveredIndex {
            hoveredIndex = newHover
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStartPoint = point
        dragCurrentPoint = point

        if let idx = indexOfWord(at: point) {
            anchorWordIndex = idx
            selectedIndices = [idx]
        } else {
            anchorWordIndex = nil
            selectedIndices.removeAll()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        dragCurrentPoint = current

        let marquee = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: max(abs(current.x - start.x), 2),
            height: max(abs(current.y - start.y), 2)
        )

        var boxMatches: Set<Int> = []
        for (i, word) in words.enumerated() {
            if convertVisionToFlippedView(word.rect).insetBy(dx: -2, dy: -2).intersects(marquee) {
                boxMatches.insert(i)
            }
        }

        if let anchor = anchorWordIndex, let currentIdx = indexOfWord(at: current) {
            let low = min(anchor, currentIdx)
            let high = max(anchor, currentIdx)
            boxMatches.formUnion(low...high)
        }

        selectedIndices = boxMatches
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let sorted = selectedIndices.sorted()
        let text = sorted.map { words[$0].word }.joined(separator: " ")

        dragStartPoint = nil
        dragCurrentPoint = nil

        if !text.isEmpty {
            onComplete?(text)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        }
    }
}

// MARK: - Single-Instance Menu Bar & CLI Entry

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print("""
    ScreenLens — Offline AI Screen Translator & OCR Search
    Usage:
      screenlens              Launch menu bar tool
      screenlens --translate  Translate active window main content (⌥⌘T)
      screenlens --area       Select area to translate (⌥⌘A)
      screenlens --search     Word select & Google search (⌥⌘S)
      screenlens --clear      Dismiss active translation overlay
    """)
    exit(0)
}

let cliCommand = args.first(where: { ["--translate", "-t", "--area", "-a", "--search", "-s", "--clear", "-c"].contains($0) })
let bundleID = Bundle.main.bundleIdentifier ?? "com.screenlens.app"
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)

if runningApps.count > 1 {
    if let cmd = cliCommand {
        DistributedNotificationCenter.default().postNotificationName(
            AppDelegate.cliCommandNotification,
            object: nil,
            userInfo: ["command": cmd],
            deliverImmediately: true
        )
    }
    exit(0)
}

if #available(macOS 14.0, *) {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.initialCLICommand = cliCommand
        app.delegate = delegate
        app.run()
    }
}
