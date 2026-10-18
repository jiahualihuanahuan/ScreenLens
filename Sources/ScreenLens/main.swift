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

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var translateHotKey: HotKey?
    var searchHotKey: HotKey?
    var resultWindow: NSWindow?
    var selectionWindow: NSWindow?
    var targetLanguage: String = "zh"
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "ScreenLens")
        }
        
        setupMenu()
        setupHotKeys()
        print("ScreenLens running. Hotkeys: ⌥⌘T translate, ⌥⌘S word-select search")
        print("App will stay running until you quit from the menu or terminal.")
    }
    
    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Translate Screen (⌥⌘T)", action: #selector(translateScreen), keyEquivalent: ""))
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
    
    // MARK: - Translate
    
    func performTranslate() async {
        print("Translate triggered")
        do {
            let imageURL = try captureFullScreen()
            let items = try await performOCR(on: imageURL)
            try? FileManager.default.removeItem(at: imageURL)
            
            guard !items.isEmpty else {
                showAlert("No text found on screen.")
                return
            }
            
            var lines: [String] = []
            for item in items.prefix(20) {
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let translated = (try? await translate(text: trimmed, to: targetLanguage)) ?? trimmed
                lines.append(translated)
            }
            
            showResultWindow(title: "Translation", text: lines.joined(separator: "\n"))
        } catch {
            print("Translate error: \(error)")
            showAlert("Translate failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Word Select Search
    
    func performWordSelectSearch() async {
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
        selectionWindow?.close()
        
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = false
        
        let view = WordSelectionView(words: words, screenFrame: frame)
        view.onComplete = { [weak self] selectedText in
            Task { @MainActor in
                self?.selectionWindow?.close()
                self?.selectionWindow = nil
                if let text = selectedText, !text.isEmpty {
                    self?.openGoogleSearch(query: text)
                }
            }
        }
        view.onCancel = { [weak self] in
            Task { @MainActor in
                self?.selectionWindow?.close()
                self?.selectionWindow = nil
            }
        }
        
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
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
    
    func showResultWindow(title: String, text: String) {
        resultWindow?.close()
        
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.level = .floating
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        textView.string = text
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 13)
        
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        window.contentView = scroll
        
        window.makeKeyAndOrderFront(nil)
        resultWindow = window
    }
    
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
                    // Split into words by whitespace and get per-word boxes
                    var searchStart = full.startIndex
                    while searchStart < full.endIndex {
                        // skip whitespace
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

// MARK: - Word Selection View

class WordSelectionView: NSView {
    let words: [WordBox]
    let screenFrame: CGRect
    var onComplete: ((String?) -> Void)?
    var onCancel: (() -> Void)?
    
    private var selectedIndices: Set<Int> = []
    private var anchorIndex: Int?
    private var isDragging = false
    
    init(words: [WordBox], screenFrame: CGRect) {
        self.words = words
        self.screenFrame = screenFrame
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Very light dim
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()
        
        for (i, word) in words.enumerated() {
            let rect = convertToView(word.rect)
            if selectedIndices.contains(i) {
                NSColor.systemBlue.withAlphaComponent(0.45).setFill()
                rect.fill()
            }
        }
    }
    
    private func convertToView(_ normalized: CGRect) -> CGRect {
        // Vision normalized box is origin bottom-left. Convert to view coords (also bottom-left).
        let x = normalized.origin.x * bounds.width
        let y = normalized.origin.y * bounds.height
        let w = normalized.size.width * bounds.width
        let h = normalized.size.height * bounds.height
        return CGRect(x: x, y: y, width: w, height: h)
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
            // Clicked empty space — cancel
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
