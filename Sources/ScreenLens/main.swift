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

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var translateHotKey: HotKey?
    var searchHotKey: HotKey?
    var overlayWindow: NSWindow?
    var targetLanguage: String = "zh" // default Chinese Simplified
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "ScreenLens")
        }
        
        setupMenu()
        setupHotKeys()
        print("ScreenLens running. Hotkeys: ⌥⌘T translate, ⌥⌘S search")
    }
    
    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Translate Screen (⌥⌘T)", action: #selector(translateScreen), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Select & Search (⌥⌘S)", action: #selector(selectAndSearch), keyEquivalent: ""))
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
            Task { @MainActor in
                self?.translateScreen()
            }
        }
        
        searchHotKey = HotKey(key: .s, modifiers: [.option, .command])
        searchHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in
                self?.selectAndSearch()
            }
        }
    }
    
    @objc func translateScreen() {
        Task { @MainActor in
            await performTranslate()
        }
    }
    
    @objc func selectAndSearch() {
        Task { @MainActor in
            await performSearch()
        }
    }
    
    // MARK: - Translate + Overlay
    
    func performTranslate() async {
        do {
            let imageURL = try captureFullScreen()
            let items = try await performOCR(on: imageURL)
            try? FileManager.default.removeItem(at: imageURL)
            
            guard !items.isEmpty else {
                showAlert("No text found on screen.")
                return
            }
            
            var translatedItems: [(String, CGRect)] = []
            for item in items {
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let translated = try await translate(text: trimmed, to: targetLanguage)
                let rect = convertBoundingBox(item.boundingBox, imageSize: NSScreen.main?.frame.size ?? .zero)
                translatedItems.append((translated, rect))
            }
            
            showOverlay(items: translatedItems)
        } catch {
            showAlert("Translate failed: \(error.localizedDescription)")
        }
    }
    
    func showOverlay(items: [(String, CGRect)]) {
        dismissOverlay()
        
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let view = OverlayView(items: items)
        view.onDismiss = { [weak self] in
            Task { @MainActor in
                self?.dismissOverlay()
            }
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        
        overlayWindow = window
        
        // Auto-dismiss after 8 seconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            dismissOverlay()
        }
    }
    
    func dismissOverlay() {
        overlayWindow?.close()
        overlayWindow = nil
    }
    
    // MARK: - Search
    
    func performSearch() async {
        do {
            let imageURL = try captureInteractiveRegion()
            let items = try await performOCR(on: imageURL)
            try? FileManager.default.removeItem(at: imageURL)
            
            let text = items.map { $0.text }.joined(separator: " ")
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !cleaned.isEmpty else {
                showAlert("No text found in selection.")
                return
            }
            
            let query = cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleaned
            if let url = URL(string: "https://www.google.com/search?q=\(query)") {
                NSWorkspace.shared.open(url)
            }
        } catch {
            showAlert("Search failed: \(error.localizedDescription)")
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
    
    nonisolated func captureInteractiveRegion() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screenlens-region-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "ScreenLens", code: 2, userInfo: [NSLocalizedDescriptionKey: "Selection cancelled or failed."])
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
    
    nonisolated func translate(text: String, to target: String) async throws -> String {
        let source = Locale.Language(identifier: "en")
        let targetLang = Locale.Language(identifier: target)
        
        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: source, target: targetLang)
            let response = try await session.translate(text)
            return response.targetText
        } else {
            return "[macOS 26+ required] \(text)"
        }
    }
    
    nonisolated func convertBoundingBox(_ box: CGRect, imageSize: CGSize) -> CGRect {
        let x = box.origin.x * imageSize.width
        let y = box.origin.y * imageSize.height
        let w = box.size.width * imageSize.width
        let h = box.size.height * imageSize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ScreenLens"
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Overlay View

class OverlayView: NSView {
    let items: [(String, CGRect)]
    var onDismiss: (() -> Void)?
    
    init(items: [(String, CGRect)]) {
        self.items = items
        super.init(frame: .zero)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        NSColor.black.withAlphaComponent(0.15).setFill()
        dirtyRect.fill()
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.75),
            .paragraphStyle: paragraph
        ]
        
        for (text, rect) in items {
            let drawRect = rect.insetBy(dx: -4, dy: -2)
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            attrStr.draw(in: drawRect)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onDismiss?()
        }
    }
    
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
