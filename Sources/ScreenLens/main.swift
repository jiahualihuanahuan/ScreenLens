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
    let boundingBox: CGRect
}

struct WordBox: Sendable {
    let word: String
    let rect: CGRect
}

struct TranslatedBlock: Sendable {
    let sourceText: String
    let translatedText: String
    let boundingBox: CGRect
}

// MARK: - Non-activating Panel

final class FloatingPanel: NSPanel {
    var allowsKey: Bool = false
    
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - App Delegate (Menu Bar Tool)

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
    
    // Menu items that update dynamically
    private var axStatusItem: NSMenuItem!
    private var screenStatusItem: NSMenuItem!
    private var historySubmenu: NSMenu!
    private var launchAtLoginItem: NSMenuItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标，作为纯 Menu Bar 应用运行
        NSApp.setActivationPolicy(.accessory)
        
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
        
        // 核心功能操作区
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
        
        // 目标语言切换子菜单
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
        
        // 最近翻译记录 & Markdown 历史文件
        historySubmenu = NSMenu()
        let historyMenuItem = NSMenuItem(title: "Recent Translations", action: nil, keyEquivalent: "")
        historyMenuItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        historyMenuItem.submenu = historySubmenu
        menu.addItem(historyMenuItem)
        refreshHistorySubmenu()
        
        menu.addItem(.separator())
        
        // 权限状态实时指示器
        axStatusItem = NSMenuItem(title: "Checking Accessibility...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(axStatusItem)
        
        screenStatusItem = NSMenuItem(title: "Checking Screen Recording...", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        menu.addItem(screenStatusItem)
        
        menu.addItem(.separator())
        
        // 开机自启与退出
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        menu.addItem(launchAtLoginItem)
        
        menu.addItem(NSMenuItem(title: "Quit ScreenLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    // 每次点开菜单栏图标时动态刷新权限与自启状态
    func menuWillOpen(_ menu: NSMenu) {
        let axTrusted = AXIsProcessTrusted()
        axStatusItem.title = axTrusted ? "Accessibility: Granted" : "Accessibility: Click to Grant..."
        axStatusItem.image = NSImage(
            systemSymbolName: axTrusted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
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
            showAlert("Could not update Launch at Login: \(error.localizedDescription)\nMake sure ScreenLens is packaged inside /Applications/ScreenLens.app.")
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
    
    // MARK: - Status Icon Visual Feedback
    
    func setStatusLoading(_ loading: Bool) {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: loading ? "ellipsis.circle" : "text.viewfinder",
                accessibilityDescription: "ScreenLens"
            )
        }
    }
    
    // MARK: - Coordinate Conversion (Quartz Top-Left <-> AppKit Bottom-Left)
    
    func screenContaining(_ rect: CGRect) -> NSScreen {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens.first!
    }
    
    func quartzToAppKit(_ quartzRect: CGRect) -> CGRect {
        // Quartz is top-left of primary; AppKit is bottom-left of primary.
        // Use the screen that actually contains the rect so external displays work.
        let screen = screenContaining(quartzRect)
        let screenTop = screen.frame.maxY
        let appKitY = screenTop - quartzRect.origin.y - quartzRect.height
        return CGRect(
            x: quartzRect.origin.x,
            y: appKitY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }
    
    func appKitToQuartz(_ appKitRect: CGRect) -> CGRect {
        let screen = screenContaining(appKitRect)
        let screenTop = screen.frame.maxY
        let quartzY = screenTop - appKitRect.maxY
        return CGRect(
            x: appKitRect.origin.x,
            y: quartzY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }
    
    // MARK: - 1. Translate Active Window (⌥⌘T)
    
    func performTranslate() async {
        dismissTranslation()
        
        guard let quartzRegion = locateActiveTextRegion() else {
            showAlert("Could not find an active window. Make sure a window is visible on screen.")
            return
        }
        
        await translateQuartzRegion(quartzRegion)
    }
    
    // MARK: - 2. Drag Area to Translate (⌥⌘A)
    
    func startAreaSelectionForTranslation() {
        dismissTranslation()
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        
        let window = FloatingPanel(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window.allowsKey = true
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(screenFrame, display: true)
        
        let view = AreaCaptureView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.onSelectRect = { [weak self, weak window] selectedViewRect in
            Task { @MainActor in
                window?.orderOut(nil)
                if self?.selectionWindow === window { self?.selectionWindow = nil }
                guard let self = self, let rect = selectedViewRect, rect.width > 24, rect.height > 16 else { return }
                let screenRect = CGRect(
                    x: screenFrame.origin.x + rect.origin.x,
                    y: screenFrame.origin.y + rect.origin.y,
                    width: rect.width,
                    height: rect.height
                )
                let quartzRect = self.appKitToQuartz(screenRect)
                try? await Task.sleep(nanoseconds: 80_000_000) // 等待选框图层彻底消失
                await self.translateQuartzRegion(quartzRect)
            }
        }
        
        window.contentView = view
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(view)
        selectionWindow = window
    }
    
    func translateQuartzRegion(_ quartzRegion: CGRect) async {
        setStatusLoading(true)
        defer { setStatusLoading(false) }
        
        do {
            let cgImage = try await captureRegionImage(quartzRegion)
            let rawItems = try await performOCR(on: cgImage)
            let mergedParagraphs = mergeIntoParagraphs(rawItems)
            
            guard !mergedParagraphs.isEmpty else {
                NSSound.beep()
                return
            }
            
            let blocks = await translateBatch(items: mergedParagraphs, to: targetLanguage)
            guard !blocks.isEmpty else { return }
            
            let appKitRegion = quartzToAppKit(quartzRegion)
            showTranslationOverlay(blocks: blocks, appKitRegion: appKitRegion)
            startInputMonitoring()
            
            // 更新菜单栏最近记录并写入本地 Markdown
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
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.setFrame(appKitRegion, display: true)
        
        let view = TranslationOverlayView(frame: NSRect(origin: .zero, size: appKitRegion.size))
        view.blocks = blocks
        window.contentView = view
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
    
    // MARK: - 3. Word Select Search (⌥⌘S)
    
    func performWordSelectSearch() async {
        dismissTranslation()
        guard let screen = NSScreen.main else { return }
        
        setStatusLoading(true)
        defer { setStatusLoading(false) }
        
        do {
            let quartzScreenRect = appKitToQuartz(screen.frame)
            let cgImage = try await captureRegionImage(quartzScreenRect)
            let words = try await extractWords(from: cgImage)
            
            guard !words.isEmpty else {
                NSSound.beep()
                return
            }
            
            showWordSelectionOverlay(words: words, screenFrame: screen.frame)
        } catch {
            showAlert("Failed to start word selection: \(error.localizedDescription)")
        }
    }
    
    func showWordSelectionOverlay(words: [WordBox], screenFrame: CGRect) {
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        
        let window = FloatingPanel(
            contentRect: screenFrame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window.allowsKey = true
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(screenFrame, display: true)
        
        let view = WordSelectionView(words: words, frame: NSRect(origin: .zero, size: screenFrame.size))
        view.onComplete = { [weak self, weak window] selectedText in
            Task { @MainActor in
                window?.orderOut(nil)
                if self?.selectionWindow === window { self?.selectionWindow = nil }
                if let text = selectedText, !text.isEmpty {
                    self?.copyToClipboard(text)
                    self?.openGoogleSearch(query: text)
                }
            }
        }
        view.onCancel = { [weak self, weak window] in
            Task { @MainActor in
                window?.orderOut(nil)
                if self?.selectionWindow === window { self?.selectionWindow = nil }
            }
        }
        
        window.contentView = view
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeFirstResponder(view)
        selectionWindow = window
    }
    
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    func openGoogleSearch(query: String) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Robust Region Locator (Supports Brave / Chrome / Electron + WindowServer)
    
    func locateActiveTextRegion() -> CGRect? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetPID = frontApp?.processIdentifier
        
        var rawRect: CGRect?
        
        if let pid = targetPID, pid != ownPID, AXIsProcessTrusted() {
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
                    if size.width > 80 && size.height > 40 {
                        rawRect = CGRect(origin: point, size: size)
                    }
                }
            }
        }
        
        if rawRect == nil {
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            if let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
                for info in windowInfoList {
                    guard let ownerPID = info["kCGWindowOwnerPID"] as? pid_t,
                          ownerPID != ownPID,
                          let layer = info["kCGWindowLayer"] as? Int,
                          layer == 0,
                          let boundsDict = info["kCGWindowBounds"] as? [String: CGFloat],
                          let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                          rect.width > 120, rect.height > 80 else {
                        continue
                    }
                    
                    if let targetPID = targetPID, ownerPID != targetPID {
                        continue
                    }
                    
                    rawRect = rect
                    break
                }
            }
        }
        
        guard var finalRect = rawRect else { return nil }
        
        if finalRect.width > 400 && finalRect.height > 300 {
            let topInset = min(max(finalRect.height * 0.08, 72), 96)
            let bottomInset = finalRect.height * 0.03
            let sideInset = finalRect.width * 0.03
            finalRect = CGRect(
                x: finalRect.origin.x + sideInset,
                y: finalRect.origin.y + topInset,
                width: finalRect.width - sideInset * 2,
                height: finalRect.height - topInset - bottomInset
            )
        }
        
        guard finalRect.width > 80, finalRect.height > 40 else { return nil }
        return finalRect
    }
    
    // MARK: - Screen Capture
    
    func captureRegionImage(_ quartzRect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(quartzRect) }) ?? content.displays.first else {
            throw NSError(domain: "ScreenLens", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        
        let localRect = CGRect(
            x: quartzRect.origin.x - display.frame.origin.x,
            y: quartzRect.origin.y - display.frame.origin.y,
            width: quartzRect.width,
            height: quartzRect.height
        )
        config.sourceRect = localRect
        config.width = Int(localRect.width * 2)
        config.height = Int(localRect.height * 2)
        config.showsCursor = false
        
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    
    // MARK: - Vision OCR & Paragraph Clustering
    
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
                    return TextItem(text: text, boundingBox: obs.boundingBox)
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
        
        let sorted = items.sorted { a, b in
            let verticalDiff = a.boundingBox.maxY - b.boundingBox.maxY
            if abs(verticalDiff) > min(a.boundingBox.height, b.boundingBox.height) * 0.45 {
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
            guard var current = paragraphs.last else {
                paragraphs.append(ParagraphAccumulator(
                    text: item.text,
                    unionBox: box,
                    lastLineBox: box,
                    firstLineMinX: box.minX,
                    avgLineHeight: box.height,
                    lineCount: 1
                ))
                continue
            }
            
            let verticalGap = current.lastLineBox.minY - box.maxY
            let maxAllowedGap = current.avgLineHeight * 0.90
            let minAllowedGap = -current.avgLineHeight * 0.40
            let isVerticallyClose = (verticalGap >= minAllowedGap && verticalGap <= maxAllowedGap)
            
            let heightRatio = box.height / max(current.avgLineHeight, 0.0001)
            let isSimilarFontSize = (heightRatio >= 0.65 && heightRatio <= 1.45)
            
            let leftEdgeDiff = min(abs(box.minX - current.lastLineBox.minX), abs(box.minX - current.firstLineMinX))
            let overlapX = min(current.unionBox.maxX, box.maxX) - max(current.unionBox.minX, box.minX)
            let minWidth = min(current.unionBox.width, box.width)
            let isHorizontallyAligned = (leftEdgeDiff < 0.08) && (overlapX > minWidth * 0.35)
            
            let sentenceEndings: Set<Character> = [".", "!", "?", "。", "！", "？", ":", "："]
            let endsWithPunctuation = current.text.last.map { sentenceEndings.contains($0) } ?? false
            let isPreviousLineShortEnd = (current.lineCount >= 1)
                && (current.lastLineBox.width < current.unionBox.width * 0.68)
                && endsWithPunctuation
            
            if isVerticallyClose && isSimilarFontSize && isHorizontallyAligned && !isPreviousLineShortEnd {
                current.text = joinTextLines(current.text, item.text)
                current.unionBox = current.unionBox.union(box)
                current.lastLineBox = box
                current.avgLineHeight = (current.avgLineHeight * CGFloat(current.lineCount) + box.height) / CGFloat(current.lineCount + 1)
                current.lineCount += 1
                paragraphs[paragraphs.count - 1] = current
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
        
        return paragraphs.map { TextItem(text: $0.text, boundingBox: $0.unionBox) }
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
                var words: [WordBox] = []
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                for obs in observations {
                    guard let recognized = obs.topCandidates(1).first else { continue }
                    let full = recognized.string
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
                        if let box = try? recognized.boundingBox(for: range) {
                            words.append(WordBox(word: word, rect: box.boundingBox))
                        }
                        searchStart = wordEnd
                    }
                }
                continuation.resume(returning: words)
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
                            boundingBox: items[idx].boundingBox
                        ))
                    }
                }
                if !results.isEmpty { return results }
            }
        }
        
        return items.map {
            TranslatedBlock(sourceText: $0.text, translatedText: $0.text, boundingBox: $0.boundingBox)
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

// MARK: - Interactive Area Capture View (⌥⌘A)

class AreaCaptureView: NSView {
    var onSelectRect: ((CGRect?) -> Void)?
    private var startPoint: NSPoint?
    private var currentRect: CGRect?
    
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.22).setFill()
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
    
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Paragraph-Aware Glassmorphic Translation Overlay View

class TranslationOverlayView: NSView {
    var blocks: [TranslatedBlock] = [] {
        didSet { needsDisplay = true }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2.0
        
        for block in blocks {
            let rect = convertToView(block.boundingBox)
            let coverRect = rect.insetBy(dx: -6, dy: -4)
            
            let path = NSBezierPath(roundedRect: coverRect, xRadius: 8, yRadius: 8)
            NSColor(calibratedWhite: 0.08, alpha: 0.90).setFill()
            path.fill()
            
            NSColor.white.withAlphaComponent(0.20).setStroke()
            path.lineWidth = 1.0
            path.stroke()
            
            let drawRect = coverRect.insetBy(dx: 6, dy: 4)
            let fontSize = optimalFontSize(for: block.translatedText, in: drawRect.size, paragraphStyle: paragraph)
            
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
            
            let attrStr = NSAttributedString(string: block.translatedText, attributes: attrs)
            attrStr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }
    
    private func optimalFontSize(for text: String, in targetSize: NSSize, paragraphStyle: NSParagraphStyle) -> CGFloat {
        let maxFont: CGFloat = 16.0
        let minFont: CGFloat = 10.5
        
        for size in stride(from: maxFont, through: minFont, by: -0.5) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .paragraphStyle: paragraphStyle
            ]
            let bound = (text as NSString).boundingRect(
                with: NSSize(width: max(targetSize.width, 40), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            if bound.height <= targetSize.height + 4 {
                return size
            }
        }
        return minFont
    }
    
    private func convertToView(_ normalized: CGRect) -> CGRect {
        let x = normalized.origin.x * bounds.width
        let y = normalized.origin.y * bounds.height
        let w = normalized.size.width * bounds.width
        let h = normalized.size.height * bounds.height
        return CGRect(x: x, y: y, width: max(w, 48), height: max(h, 22))
    }
}

// MARK: - Word Selection View

class WordSelectionView: NSView {
    let words: [WordBox]
    var onComplete: ((String?) -> Void)?
    var onCancel: (() -> Void)?
    
    private var selectedIndices: Set<Int> = []
    private var anchorIndex: Int?
    private var isDragging = false
    
    init(words: [WordBox], frame: NSRect = .zero) {
        self.words = words
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()
        
        for (i, word) in words.enumerated() {
            let rect = convertToView(word.rect).insetBy(dx: -2, dy: -1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            if selectedIndices.contains(i) {
                NSColor.systemBlue.withAlphaComponent(0.55).setFill()
                path.fill()
            } else {
                NSColor.white.withAlphaComponent(0.12).setStroke()
                path.lineWidth = 0.8
                path.stroke()
            }
        }
    }
    
    private func convertToView(_ normalized: CGRect) -> CGRect {
        let x = normalized.origin.x * bounds.width
        let y = normalized.origin.y * bounds.height
        let w = normalized.size.width * bounds.width
        let h = normalized.size.height * bounds.height
        return CGRect(x: x, y: y, width: max(w, 16), height: max(h, 14))
    }
    
    private func indexOfWord(at point: NSPoint) -> Int? {
        for (i, word) in words.enumerated() {
            if convertToView(word.rect).insetBy(dx: -4, dy: -2).contains(point) {
                return i
            }
        }
        return nil
    }
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let idx = indexOfWord(at: point) {
            anchorIndex = idx
            selectedIndices = [idx]
            isDragging = true
            needsDisplay = true
        } else {
            onCancel?()
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let anchor = anchorIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let current = indexOfWord(at: point) {
            let low = min(anchor, current)
            let high = max(anchor, current)
            selectedIndices = Set(low...high)
            needsDisplay = true
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let sorted = selectedIndices.sorted()
        let text = sorted.map { words[$0].word }.joined(separator: " ")
        onComplete?(text.isEmpty ? nil : text)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        }
    }
    
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Single-Instance Menu Bar App Entry

let bundleID = Bundle.main.bundleIdentifier ?? "com.screenlens.app"
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
if runningApps.count > 1 {
    // 防止重复双击启动多个状态栏图标
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
