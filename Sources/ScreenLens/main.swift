import AppKit
import HotKey
import Vision
import Translation
import ScreenCaptureKit
import ApplicationServices
import ServiceManagement
import Foundation

// MARK: - Models

struct TextItem: Sendable {
    let text: String
    let boundingBox: CGRect // Vision normalized (0...1, bottom-left origin)
    let avgLineHeight: CGFloat
}

struct WordBox: Sendable {
    let word: String
    let rect: CGRect // Vision normalized (0...1, bottom-left origin)
}

struct TranslatedBlock: Sendable {
    let sourceText: String
    let translatedText: String
    let boundingBox: CGRect // Vision normalized (0...1, bottom-left origin)
    let avgLineHeight: CGFloat
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

// MARK: - App Delegate (Menu Bar Tool)

@available(macOS 14.0, *)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    
    /// Remembers the last frontmost non-ScreenLens app PID
    var lastActiveAppPID: pid_t?
    
    private var axStatusItem: NSMenuItem!
    private var screenStatusItem: NSMenuItem!
    private var historySubmenu: NSMenu!
    private var launchAtLoginItem: NSMenuItem!
    
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
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "ScreenLens")
            button.imagePosition = .imageLeading
        }
        
        setupMenu()
        setupHotKeys()
    }
    
    // MARK: - Menu Bar UI Construction
    
    func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        let headerItem = NSMenuItem(title: "ScreenLens — Offline AI Translator", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())
        
        let activeTranslateItem = NSMenuItem(title: "Translate Active Window", action: #selector(translateScreen), keyEquivalent: "t")
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
        axStatusItem.title = axTrusted ? "Accessibility: Granted" : "Accessibility: Optional (WindowServer Active)"
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
    
    // MARK: - Coordinate Conversion (Quartz Top-Left <-> AppKit Bottom-Left)
    
    func quartzToAppKit(_ quartzRect: CGRect) -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let appKitY = primaryScreenHeight - quartzRect.origin.y - quartzRect.height
        return CGRect(
            x: quartzRect.origin.x,
            y: appKitY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }
    
    func appKitToQuartz(_ appKitRect: CGRect) -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let quartzY = primaryScreenHeight - appKitRect.maxY
        return CGRect(
            x: appKitRect.origin.x,
            y: quartzY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }
    
    func screenContaining(quartzRect: CGRect) -> NSScreen {
        let appKitRect = quartzToAppKit(quartzRect)
        for screen in NSScreen.screens {
            if screen.frame.intersects(appKitRect) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
    
    func currentMouseScreen() -> NSScreen {
        let mouseLoc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
    
    // MARK: - 1. Translate Active Window (⌥⌘T)
    
    func performTranslate() async {
        dismissTranslation()
        closeSelectionWindow()
        
        // Slight delay if triggered from Menu Bar so the menu closes cleanly before capture
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        let quartzRegion = locateActiveTextRegion()
        await translateQuartzRegion(quartzRegion)
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
                guard let self = self, let rect = selectedTopLeftRect, rect.width > 20, rect.height > 14 else { return }
                let screenQuartz = self.appKitToQuartz(screenFrame)
                let targetQuartz = CGRect(
                    x: screenQuartz.origin.x + rect.origin.x,
                    y: screenQuartz.origin.y + rect.origin.y,
                    width: rect.width,
                    height: rect.height
                )
                try? await Task.sleep(nanoseconds: 60_000_000)
                await self.translateQuartzRegion(targetQuartz)
            }
        }
        
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        selectionWindow = window
    }
    
    func translateQuartzRegion(_ requestedQuartzRegion: CGRect) async {
        setStatusLoading(true)
        defer { setStatusLoading(false) }
        
        do {
            let (cgImage, actualQuartzRegion) = try await captureRegionImage(requestedQuartzRegion)
            let rawItems = try await performOCR(on: cgImage)
            let mergedParagraphs = mergeIntoParagraphs(rawItems)
            // Only keep text well inside the capture (main content, not sidebar/edge)
            let filtered = mergedParagraphs.filter { item in
                let box = item.boundingBox
                // Must be clearly inside the region
                if box.minX < 0.10 || box.maxX > 0.90 { return false }
                // Skip narrow sidebar strips
                if box.width < 0.18 { return false }
                // Skip tiny UI labels
                if item.text.count < 12 { return false }
                return true
            }
            
            guard !filtered.isEmpty else {
                NSSound.beep()
                return
            }
            
            let blocks = await translateBatch(items: filtered, to: targetLanguage)
            guard !blocks.isEmpty else { return }
            
            let appKitRegion = quartzToAppKit(actualQuartzRegion)
            showTranslationOverlay(blocks: blocks, appKitRegion: appKitRegion)
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
        // Restore focus back to the previous app so ScreenLens doesn't stay frontmost
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
            let words = try await extractWords(from: cgImage)
            
            guard !words.isEmpty else {
                NSSound.beep()
                return
            }
            
            let actualAppKitFrame = quartzToAppKit(actualQuartzRect)
            showWordSelectionOverlay(words: words, screenFrame: actualAppKitFrame)
        } catch {
            showAlert("Failed to start word selection: \(error.localizedDescription)")
        }
    }
    
    func showWordSelectionOverlay(words: [WordBox], screenFrame: CGRect) {
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
        
        let view = WordSelectionView(words: words, frame: NSRect(origin: .zero, size: screenFrame.size))
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
    
    // MARK: - Fail-Safe Active Window & Screen Region Locator
    
    func locateActiveTextRegion() -> CGRect {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let effectiveTargetPID: pid_t? = (frontPID != nil && frontPID != ownPID) ? frontPID : lastActiveAppPID
        
        // 1. Try AXUIElement first if Accessibility permission is currently active
        if let pid = effectiveTargetPID, pid != ownPID, AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, true as CFBoolean)
            
            var windowObj: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObj) != .success {
                if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowObj) != .success {
                    var windowsList: AnyObject?
                    if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsList) == .success,
                       let windows = windowsList as? [AXUIElement],
                       let firstWin = windows.first {
                        windowObj = firstWin
                    }
                }
            }
            
            if let window = windowObj as! AXUIElement? {
                var posValue: AnyObject?
                var sizeValue: AnyObject?
                if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
                   AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success {
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                    if size.width > 100 && size.height > 80 {
                        return CGRect(origin: point, size: size)
                    }
                }
            }
        }
        
        // 2. WindowServer (CGWindowListCopyWindowInfo) with 64-bit NSNumber & CFDictionary safe bridging
        let ignoredOwners: Set<String> = [
            "Window Server", "WindowServer", "Dock", "Control Center",
            "SystemUIServer", "Notification Center", "Wallpaper"
        ]
        
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
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
                
                if let targetPID = effectiveTargetPID, ownerPID == targetPID {
                    return rect
                }
            }
            
            // If effectiveTargetPID had no standard layer-0 window, use the topmost visible window on screen
            if let fallbackWindowRect = topmostAnyAppRect {
                return fallbackWindowRect
            }
        }
        
        // 3. Ultimate fallback: use the active monitor's visible frame so translation never fails
        let screen = currentMouseScreen()
        return appKitToQuartz(screen.visibleFrame)
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
    
    // MARK: - Vision OCR & Column-Aware Paragraph Clustering
    
    nonisolated func performOCR(on cgImage: CGImage) async throws -> [TextItem] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let items: [TextItem] = observations.compactMap { obs in
                    guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    return TextItem(text: text, boundingBox: obs.boundingBox, avgLineHeight: obs.boundingBox.height)
                }
                continuation.resume(returning: items)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    nonisolated func mergeIntoParagraphs(_ items: [TextItem]) -> [TextItem] {
        guard items.count > 1 else { return items }
        
        // Sort top-to-bottom, then left-to-right
        let sorted = items.sorted { a, b in
            let verticalDiff = a.boundingBox.maxY - b.boundingBox.maxY
            if abs(verticalDiff) > min(a.boundingBox.height, b.boundingBox.height) * 0.4 {
                return a.boundingBox.maxY > b.boundingBox.maxY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        
        struct ParagraphAccumulator {
            var text: String
            var unionBox: CGRect
            var lastLineBox: CGRect
            var firstLineMinX: CGFloat
            var avgLineHeight: CGFloat
            var lineCount: Int
        }
        
        var paragraphs: [ParagraphAccumulator] = []
        
        for item in sorted {
            let box = item.boundingBox
            var mergedIndex: Int?
            
            // Only consider the most recent paragraph that is still close
            for idx in paragraphs.indices.reversed() {
                let candidate = paragraphs[idx]
                
                // Same-line continuation (text wrapped horizontally)
                let sameLineVerticalOverlap = min(candidate.lastLineBox.maxY, box.maxY) - max(candidate.lastLineBox.minY, box.minY)
                let minH = min(candidate.lastLineBox.height, box.height)
                let horizontalGap = box.minX - candidate.lastLineBox.maxX
                if sameLineVerticalOverlap > minH * 0.4 && horizontalGap >= -0.02 && horizontalGap < candidate.avgLineHeight * 2.5 {
                    mergedIndex = idx
                    break
                }
                
                // Vertical gap between this line and the last line of the candidate
                let verticalGap = candidate.lastLineBox.minY - box.maxY
                
                // Large gap = definite paragraph break
                if verticalGap > candidate.avgLineHeight * 1.8 {
                    continue
                }
                
                // Keep lines together if they are reasonably close and in the same column
                let isVerticallyClose = verticalGap >= -candidate.avgLineHeight * 0.5 && verticalGap <= candidate.avgLineHeight * 1.4
                
                let heightRatio = box.height / max(candidate.avgLineHeight, 0.0001)
                let isSimilarFontSize = heightRatio >= 0.6 && heightRatio <= 1.6
                
                // Same column: left edges close OR substantial horizontal overlap
                let leftEdgeDiff = min(abs(box.minX - candidate.lastLineBox.minX), abs(box.minX - candidate.firstLineMinX))
                let overlapX = min(candidate.unionBox.maxX, box.maxX) - max(candidate.unionBox.minX, box.minX)
                let minWidth = min(candidate.unionBox.width, box.width)
                let isSameColumn = leftEdgeDiff < 0.12 || overlapX > minWidth * 0.35
                
                // Only force a break on a clear sentence end + short line + larger gap
                let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？"]
                let endsWithPunctuation = candidate.text.last.map { sentenceEndings.contains($0) } ?? false
                let isClearParagraphEnd = endsWithPunctuation
                    && candidate.lastLineBox.width < candidate.unionBox.width * 0.55
                    && verticalGap > candidate.avgLineHeight * 0.6
                
                if isVerticallyClose && isSimilarFontSize && isSameColumn && !isClearParagraphEnd {
                    mergedIndex = idx
                    break
                }
            }
            
            if let idx = mergedIndex {
                var current = paragraphs[idx]
                current.text = joinTextLines(current.text, item.text)
                current.unionBox = current.unionBox.union(box)
                current.lastLineBox = box
                current.avgLineHeight = (current.avgLineHeight * CGFloat(current.lineCount) + box.height) / CGFloat(current.lineCount + 1)
                current.lineCount += 1
                paragraphs[idx] = current
            } else {
                paragraphs.append(ParagraphAccumulator(
                    text: item.text,
                    unionBox: box,
                    lastLineBox: box,
                    firstLineMinX: box.minX,
                    avgLineHeight: box.height,
                    lineCount: 1
                ))
            }
        }
        
        return paragraphs.map {
            TextItem(text: $0.text, boundingBox: $0.unionBox, avgLineHeight: $0.avgLineHeight)
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
    
    nonisolated func extractWords(from cgImage: CGImage) async throws -> [WordBox] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                var rawWords: [WordBox] = []
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                for obs in observations {
                    guard let recognized = obs.topCandidates(1).first else { continue }
                    let full = recognized.string
                    let totalCount = max(full.count, 1)
                    let lineBox = obs.boundingBox
                    
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
                        let range = searchStart..<wordEnd
                        let word = String(full[range])
                        
                        if let box = try? recognized.boundingBox(for: range),
                           box.boundingBox.width > 0.001, box.boundingBox.height > 0.001 {
                            rawWords.append(WordBox(word: word, rect: box.boundingBox))
                        } else {
                            let startOffset = CGFloat(full.distance(from: full.startIndex, to: searchStart)) / CGFloat(totalCount)
                            let endOffset = CGFloat(full.distance(from: full.startIndex, to: wordEnd)) / CGFloat(totalCount)
                            let approxRect = CGRect(
                                x: lineBox.origin.x + lineBox.width * startOffset,
                                y: lineBox.origin.y,
                                width: max(lineBox.width * (endOffset - startOffset), 0.01),
                                height: lineBox.height
                            )
                            rawWords.append(WordBox(word: word, rect: approxRect))
                        }
                        searchStart = wordEnd
                    }
                }
                
                let sortedWords = rawWords.sorted { a, b in
                    let verticalDiff = a.rect.maxY - b.rect.maxY
                    if abs(verticalDiff) > min(a.rect.height, b.rect.height) * 0.45 {
                        return a.rect.maxY > b.rect.maxY
                    }
                    return a.rect.minX < b.rect.minX
                }
                continuation.resume(returning: sortedWords)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - Batch Translation
    
    nonisolated func translateBatch(items: [TextItem], to target: String) async -> [TranslatedBlock] {
        let source = Locale.Language(identifier: "en")
        let targetLang = Locale.Language(identifier: target)
        
        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: source, target: targetLang)
            let requests = items.enumerated().map { idx, item in
                TranslationSession.Request(sourceText: item.text, clientIdentifier: "\(idx)")
            }
            if let responses = try? await session.translations(from: requests) {
                var results: [TranslatedBlock] = []
                for response in responses {
                    if let idStr = response.clientIdentifier, let idx = Int(idStr), idx < items.count {
                        results.append(TranslatedBlock(
                            sourceText: items[idx].text,
                            translatedText: response.targetText,
                            boundingBox: items[idx].boundingBox,
                            avgLineHeight: items[idx].avgLineHeight
                        ))
                    }
                }
                if !results.isEmpty { return results }
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
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5
        
        for block in blocks {
            let rect = convertVisionToFlippedView(block.boundingBox)
            let originalLineHeightPts = max(block.avgLineHeight * bounds.height, 12.0)
            // Exact bounds — no expansion so the box stays on the original text
            let coverRect = rect
            
            let path = NSBezierPath(roundedRect: coverRect, xRadius: 6, yRadius: 6)
            NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
            path.fill()
            
            NSColor.white.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 1.0
            path.stroke()
            
            let drawRect = coverRect.insetBy(dx: 4, dy: 2)
            let fontSize = optimalFontSize(
                for: block.translatedText,
                in: drawRect.size,
                originalLineHeight: originalLineHeightPts,
                paragraphStyle: paragraph
            )
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
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
        paragraphStyle: NSParagraphStyle
    ) -> CGFloat {
        let maxFont = min(max(originalLineHeight * 0.95, 11.0), 36.0)
        let minFont: CGFloat = 9.0
        
        for size in stride(from: maxFont, through: minFont, by: -0.5) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .paragraphStyle: paragraphStyle
            ]
            let bound = (text as NSString).boundingRect(
                with: NSSize(width: max(targetSize.width, 32), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            if bound.height <= targetSize.height + 4 {
                return size
            }
        }
        return minFont
    }
    
    private func convertVisionToFlippedView(_ normalized: CGRect) -> CGRect {
        let x = normalized.origin.x * bounds.width
        let y = (1.0 - normalized.maxY) * bounds.height
        let w = normalized.size.width * bounds.width
        let h = normalized.size.height * bounds.height
        return CGRect(x: x, y: y, width: max(w, 28), height: max(h, 16))
    }
}

// MARK: - Word Selection & Rubber-Band Marquee Search View (⌥⌘S, Top-Left Flipped)

class WordSelectionView: NSView {
    let words: [WordBox]
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
    
    init(words: [WordBox], frame: NSRect) {
        self.words = words
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
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            
            if selectedIndices.contains(i) {
                NSColor.systemBlue.withAlphaComponent(0.65).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.8).setStroke()
                path.lineWidth = 1.0
                path.stroke()
            } else if hoveredIndex == i {
                NSColor.systemCyan.withAlphaComponent(0.35).setFill()
                path.fill()
                NSColor.systemCyan.setStroke()
                path.lineWidth = 1.2
                path.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.16).setStroke()
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
        let pillRect = CGRect(x: (bounds.width - pillWidth) / 2, y: 36, width: pillWidth, height: 34)
        
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
        return CGRect(x: x, y: y, width: max(w, 14), height: max(h, 12))
    }
    
    private func indexOfWord(at point: NSPoint) -> Int? {
        for (i, word) in words.enumerated() {
            if convertVisionToFlippedView(word.rect).insetBy(dx: -5, dy: -3).contains(point) {
                return i
            }
        }
        return nil
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

// MARK: - Single-Instance Menu Bar App Entry

let bundleID = Bundle.main.bundleIdentifier ?? "com.screenlens.app"
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
if runningApps.count > 1 {
    exit(0)
}

if #available(macOS 14.0, *) {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
