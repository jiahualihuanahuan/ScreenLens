import AppKit
import HotKey
import Vision
import Translation
import ScreenCaptureKit
import ApplicationServices
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

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var translateHotKey: HotKey?
    var searchHotKey: HotKey?
    var overlayWindow: NSWindow?
    var selectionWindow: NSWindow?
    var targetLanguage: String = "zh-Hans"
    var inputMonitors: [Any] = []
    var isTranslating = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "ScreenLens")
        }
        
        setupMenu()
        setupHotKeys()
        print("ScreenLens running. Hotkeys: ⌥⌘T translate active area, ⌥⌘S word-select search")
    }
    
    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Translate Active Area (⌥⌘T)", action: #selector(translateScreen), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Word Select & Search (⌥⌘S)", action: #selector(selectAndSearch), keyEquivalent: ""))
        menu.addItem(.separator())
        
        let langMenu = NSMenu()
        let languages: [(title: String, code: String)] = [
            ("ZH-HANS", "zh-Hans"),
            ("JA", "ja"),
            ("KO", "ko"),
            ("FR", "fr"),
            ("DE", "de"),
            ("ES", "es"),
            ("EN", "en")
        ]
        for lang in languages {
            let item = NSMenuItem(title: lang.title, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang.code
            if lang.code == targetLanguage { item.state = .on }
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Target Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)
        
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    @objc func setLanguage(_ sender: NSMenuItem) {
        if let lang = sender.representedObject as? String {
            targetLanguage = lang
            if let submenu = sender.menu {
                for item in submenu.items {
                    item.state = (item.representedObject as? String == lang) ? .on : .off
                }
            }
        }
    }
    
    func setupHotKeys() {
        translateHotKey = HotKey(key: .t, modifiers: [.option, .command])
        translateHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.translateScreen() }
        }
        
        searchHotKey = HotKey(key: .s, modifiers: [.option, .command])
        searchHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.selectAndSearch() }
        }
    }
    
    @objc func translateScreen() {
        Task { @MainActor in await performTranslate() }
    }
    
    @objc func selectAndSearch() {
        Task { @MainActor in await performWordSelectSearch() }
    }
    
    // MARK: - Coordinate Conversion (Quartz Top-Left -> AppKit Bottom-Left)
    
    func quartzToAppKit(_ quartzRect: CGRect) -> CGRect {
        // Quartz 主屏幕原点在左上角，AppKit 主屏幕原点在左下角
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        let appKitY = primaryScreenHeight - quartzRect.origin.y - quartzRect.height
        return CGRect(
            x: quartzRect.origin.x,
            y: appKitY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }
    
    // MARK: - Translate (Active Area Only)
    
    func performTranslate() async {
        dismissTranslation()
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            showAlert("Accessibility permission is required. Enable ScreenLens in System Settings → Privacy & Security → Accessibility.")
            return
        }
        
        guard let quartzRegion = locateActiveTextRegion() else {
            showAlert("Could not find an active window.")
            return
        }
        
        do {
            let cgImage = try await captureRegionImage(quartzRegion)
            let items = try await performOCR(on: cgImage)
            
            let validItems = items.compactMap { item -> TextItem? in
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : TextItem(text: trimmed, boundingBox: item.boundingBox)
            }
            
            guard !validItems.isEmpty else {
                showAlert("No text found in the active area.")
                return
            }
            
            let blocks = await translateBatch(items: validItems, to: targetLanguage)
            guard !blocks.isEmpty else { return }
            
            let appKitRegion = quartzToAppKit(quartzRegion)
            showTranslationOverlay(blocks: blocks, appKitRegion: appKitRegion)
            startInputMonitoring()
            await HistoryLogger.shared.record(blocks: blocks)
        } catch {
            print("Translate error: \(error)")
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
        
        // 移除轻微 .mouseMoved 误触，改为点击、滚轮或按键时关闭浮层
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
    
    // MARK: - Word Select Search
    
    func performWordSelectSearch() async {
        dismissTranslation()
        guard let screen = NSScreen.main else { return }
        
        do {
            // 将当前屏幕转换回 Quartz 坐标进行内存级全屏截取
            let quartzScreenRect = CGRect(
                x: screen.frame.origin.x,
                y: (NSScreen.screens.first?.frame.height ?? screen.frame.height) - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            let cgImage = try await captureRegionImage(quartzScreenRect)
            let words = try await extractWords(from: cgImage)
            
            guard !words.isEmpty else {
                showAlert("No words found on screen.")
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
        window.allowsKey = true // 允许接收 Esc 键事件
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(screenFrame, display: true)
        
        let view = WordSelectionView(words: words)
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
    
    // MARK: - Region & In-Memory Capture
    
    nonisolated func locateActiveTextRegion() -> CGRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let appElement = focusedApp as! AXUIElement? else {
            return nil
        }
        
        var windowElement: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowElement) == .success,
              let window = windowElement as! AXUIElement? else {
            return nil
        }
        
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }
        
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        
        var raw = CGRect(origin: point, size: size)
        if raw.width > 400 && raw.height > 300 {
            raw = CGRect(
                x: raw.origin.x + raw.width * 0.04,
                y: raw.origin.y + raw.height * 0.06,
                width: raw.width * 0.92,
                height: raw.height * 0.86
            )
        }
        
        guard raw.width > 80, raw.height > 40 else { return nil }
        return raw
    }
    
    func captureRegionImage(_ quartzRect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // 匹配包含目标区域的显示器（支持多显示器扩展）
        guard let display = content.displays.first(where: { $0.frame.intersects(quartzRect) }) ?? content.displays.first else {
            throw NSError(domain: "ScreenLens", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        
        // 排除当前应用自身窗口，防止连续触发时截取到自身的悬浮层
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        
        // 转换为相对于当前 SCDisplay 的局部坐标
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
    
    // MARK: - Vision OCR (Direct CGImage)
    
    nonisolated func performOCR(on cgImage: CGImage) async throws -> [TextItem] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let items: [TextItem] = observations.compactMap { obs in
                    guard let text = obs.topCandidates(1).first?.string else { return nil }
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

// MARK: - History Logger (Bilingual Markdown)

actor HistoryLogger {
    static let shared = HistoryLogger()
    private let markdownFileURL: URL
    private var lastHash: Int = 0
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ScreenLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        markdownFileURL = dir.appendingPathComponent("Translation_History.md")
    }
    
    func record(blocks: [TranslatedBlock]) {
        guard !blocks.isEmpty else { return }
        let combinedSource = blocks.map(\.sourceText).joined(separator: "\n")
        let combinedTarget = blocks.map(\.translatedText).joined(separator: "\n")
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

// MARK: - Glassmorphic Translation Overlay View

class TranslationOverlayView: NSView {
    var blocks: [TranslatedBlock] = [] {
        didSet { needsDisplay = true }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        
        for block in blocks {
            let rect = convertToView(block.boundingBox)
            let coverRect = rect.insetBy(dx: -6, dy: -3)
            
            // Glassmorphic 拟态半透明深色卡片 + 1px 微光描边
            let path = NSBezierPath(roundedRect: coverRect, xRadius: 6, yRadius: 6)
            NSColor(calibratedWhite: 0.10, alpha: 0.86).setFill()
            path.fill()
            
            NSColor.white.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 1.0
            path.stroke()
            
            // 根据原文本框高度自适应字体大小
            let dynamicFontSize = max(min(rect.height * 0.72, 16), 11)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: dynamicFontSize, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
            
            let drawRect = coverRect.insetBy(dx: 5, dy: 2)
            let attrStr = NSAttributedString(string: block.translatedText, attributes: attrs)
            attrStr.draw(in: drawRect)
        }
    }
    
    private func convertToView(_ normalized: CGRect) -> CGRect {
        let x = normalized.origin.x * bounds.width
        let y = normalized.origin.y * bounds.height
        let w = normalized.size.width * bounds.width
        let h = normalized.size.height * bounds.height
        return CGRect(x: x, y: y, width: max(w, 40), height: max(h, 20))
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
    
    init(words: [WordBox]) {
        self.words = words
        super.init(frame: .zero)
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
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }
    
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
