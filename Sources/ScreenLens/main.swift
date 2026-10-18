import AppKit
import HotKey
import Vision
import Translation
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
    let text: String
    let boundingBox: CGRect
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var translateHotKey: HotKey?
    var searchHotKey: HotKey?
    var overlayWindow: NSWindow?
    var selectionWindow: NSWindow?
    var targetLanguage: String = "zh"
    var liveTranslateTask: Task<Void, Never>?
    var isLiveTranslating = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "ScreenLens")
        }
        
        setupMenu()
        setupHotKeys()
        print("ScreenLens running. Hotkeys: ⌥⌘T live translate, ⌥⌘S word-select search")
        print("Press ⌥⌘T again or Escape to stop live translation.")
        print("App stays running until you quit from the menu or terminal.")
    }
    
    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Live Translate (⌥⌘T)", action: #selector(translateScreen), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Word Select & Search (⌥⌘S)", action: #selector(selectAndSearch), keyEquivalent: ""))
        menu.addItem(.separator())
        
        let langMenu = NSMenu()
        for lang in ["zh", "ja", "ko", "fr", "de", "es", "en"] {
            let item = NSMenuItem(title: lang.uppercased(), action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.representedObject = lang
            if lang == targetLanguage { item.state = .on }
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
            Task { @MainActor in self?.toggleLiveTranslate() }
        }
        
        searchHotKey = HotKey(key: .s, modifiers: [.option, .command])
        searchHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.selectAndSearch() }
        }
    }
    
    @objc func translateScreen() {
        toggleLiveTranslate()
    }
    
    @objc func selectAndSearch() {
        Task { @MainActor in await performWordSelectSearch() }
    }
    
    // MARK: - Live Translate
    
    func toggleLiveTranslate() {
        if isLiveTranslating {
            stopLiveTranslate()
        } else {
            startLiveTranslate()
        }
    }
    
    func startLiveTranslate() {
        print("Starting live translation")
        isLiveTranslating = true
        ensureOverlayWindow()
        
        liveTranslateTask = Task { @MainActor in
            while isLiveTranslating && !Task.isCancelled {
                await refreshTranslation()
                try? await Task.sleep(nanoseconds: 1_500_000_000) // refresh every 1.5s
            }
        }
    }
    
    func stopLiveTranslate() {
        print("Stopping live translation")
        isLiveTranslating = false
        liveTranslateTask?.cancel()
        liveTranslateTask = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }
    
    func ensureOverlayWindow() {
        if overlayWindow != nil { return }
        
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true // click-through so you can scroll the page
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: true)
        
        let view = TranslationOverlayView(blocks: [])
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        overlayWindow = window
        print("Live overlay window created (click-through)")
    }
    
    func refreshTranslation() async {
        guard isLiveTranslating else { return }
        do {
            let imageURL = try captureFullScreen()
            let items = try await performOCR(on: imageURL)
            try? FileManager.default.removeItem(at: imageURL)
            
            var blocks: [TranslatedBlock] = []
            for item in items {
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let translated = (try? await translate(text: trimmed, to: targetLanguage)) ?? trimmed
                blocks.append(TranslatedBlock(text: translated, boundingBox: item.boundingBox))
            }
            
            updateOverlay(blocks: blocks)
        } catch {
            print("Live refresh error: \(error)")
        }
    }
    
    func updateOverlay(blocks: [TranslatedBlock]) {
        guard let window = overlayWindow,
              let view = window.contentView as? TranslationOverlayView else { return }
        view.blocks = blocks
        view.needsDisplay = true
    }
    
    // MARK: - Word Select Search
    
    func performWordSelectSearch() async {
        // Stop live translate if running
        if isLiveTranslating { stopLiveTranslate() }
        
        print("Word select search triggered")
        do {
            let imageURL = try captureFullScreen()
            let words = try await extractWords(from: imageURL)
            try? FileManager.default.removeItem(at: imageURL)
            
            guard !words.isEmpty else {
                showAlert("No words found on screen.")
                return
            }
            
            showWordSelectionOverlay(words: words)
        } catch {
            print("Word select error: \(error)")
            showAlert("Failed to start word selection: \(error.localizedDescription)")
        }
    }
    
    func showWordSelectionOverlay(words: [WordBox]) {
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .statusBar
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: true)
        
        let view = WordSelectionView(words: words)
        view.onComplete = { [weak self, weak window] selectedText in
            DispatchQueue.main.async {
                window?.orderOut(nil)
                if self?.selectionWindow === window {
                    self?.selectionWindow = nil
                }
                if let text = selectedText, !text.isEmpty {
                    self?.openGoogleSearch(query: text)
                }
            }
        }
        view.onCancel = { [weak self, weak window] in
            DispatchQueue.main.async {
                window?.orderOut(nil)
                if self?.selectionWindow === window {
                    self?.selectionWindow = nil
                }
            }
        }
        
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        selectionWindow = window
    }
    
    func openGoogleSearch(query: String) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            NSWorkspace.shared.open(url)
            print("Opened search for: \(query)")
        }
    }
    
    // MARK: - Helpers
    
    nonisolated func captureFullScreen() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenlens-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "ScreenLens", code: 1, userInfo: [NSLocalizedDescriptionKey: "Screen capture failed. Grant Screen Recording permission."])
        }
        return url
    }
    
    nonisolated func performOCR(on imageURL: URL) async throws -> [TextItem] {
        guard let cgImage = NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ScreenLens", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
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
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    nonisolated func extractWords(from imageURL: URL) async throws -> [WordBox] {
        guard let cgImage = NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ScreenLens", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
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
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    nonisolated func translate(text: String, to target: String) async throws -> String {
        let source = Locale.Language(identifier: "en")
        let targetLang = Locale.Language(identifier: target)
        if #available(macOS 26.0, *) {
            do {
                let session = TranslationSession(installedSource: source, target: targetLang)
                let response = try await session.translate(text)
                return response.targetText
            } catch {
                return text
            }
        } else {
            return text
        }
    }
    
    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ScreenLens"
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Translation Overlay View

class TranslationOverlayView: NSView {
    var blocks: [TranslatedBlock] = []
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Very light dim so original content is still visible for scrolling
        NSColor.black.withAlphaComponent(0.05).setFill()
        bounds.fill()
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.75),
            .paragraphStyle: paragraph
        ]
        
        for block in blocks {
            let rect = convertToView(block.boundingBox)
            let drawRect = rect.insetBy(dx: -2, dy: -1)
            let attrStr = NSAttributedString(string: block.text, attributes: attrs)
            attrStr.draw(in: drawRect)
        }
    }
    
    private func convertToView(_ normalized: CGRect) -> CGRect {
        let x = normalized.origin.x * bounds.width
        let y = normalized.origin.y * bounds.height
        let w = normalized.size.width * bounds.width
        let h = normalized.size.height * bounds.height
        return CGRect(x: x, y: y, width: max(w, 30), height: max(h, 16))
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
        NSColor.black.withAlphaComponent(0.1).setFill()
        bounds.fill()
        
        for (i, word) in words.enumerated() {
            let rect = convertToView(word.rect)
            if selectedIndices.contains(i) {
                NSColor.systemBlue.withAlphaComponent(0.5).setFill()
                rect.fill()
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
            if convertToView(word.rect).contains(point) {
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

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
