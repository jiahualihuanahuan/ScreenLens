import AppKit
import HotKey
import Vision
import Translation
import Foundation

// MARK: - App Delegate

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
            // refresh menu states
            if let submenu = sender.menu {
                for item in submenu.items {
                    item.state = (item.representedObject as? String == lang) ? .on : .off
                }
            }
        }
    }
    
    func setupHotKeys() {
        translateHotKey = HotKey(key: .t, modifiers: [.option, .command])
        translateHotKey?.keyDownHandler = { [weak self] in self?.translateScreen() }
        
        searchHotKey = HotKey(key: .s, modifiers: [.option, .command])
        searchHotKey?.keyDownHandler = { [weak self] in self?.selectAndSearch() }
    }
    
    @objc func translateScreen() {
        Task { await performTranslate() }
    }
    
    @objc func selectAndSearch() {
        Task { await performSearch() }
    }
    
    // MARK: - Translate + Overlay
    
    func performTranslate() async {
        do {
            let imageURL = try captureFullScreen()
            let observations = try await performOCRWithBoxes(on: imageURL)
            try? FileManager.default.removeItem(at: imageURL)
            
            guard !observations.isEmpty else {
                await showAlert("No text found on screen.")
                return
            }
            
            var translatedItems: [(String, CGRect)] = []
            for obs in observations {
                guard let text = obs.topCandidates(1).first?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let translated = try await translate(text: text, to: targetLanguage)
                let rect = convertBoundingBox(obs.boundingBox, imageSize: NSScreen.main?.frame.size ?? .zero)
                translatedItems.append((translated, rect))
            }
            
            await MainActor.run {
                self.showOverlay(items: translatedItems)
            }
        } catch {
            await showAlert("Translate failed: \(error.localizedDescription)")
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
        view.onDismiss = { [weak self] in self?.dismissOverlay() }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        
        overlayWindow = window
        
        // Auto-dismiss after 8 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.dismissOverlay()
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
            let observations = try await performOCRWithBoxes(on: imageURL)
            try? FileManager.default.removeItem(at: imageURL)
            
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !cleaned.isEmpty else {
                await showAlert("No text found in selection.")
                return
            }
            
            await MainActor.run {
                let query = cleaned.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleaned
                if let url = URL(string: "https://www.google.com/search?q=\(query)") {
                    NSWorkspace.shared.open(url)
                }
            }
        } catch {
            await showAlert("Search failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    func captureFullScreen() throws -> URL {
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
    
    func captureInteractiveRegion() throws -> URL {
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
    
    func performOCRWithBoxes(on imageURL: URL) async throws -> [VNRecognizedTextObservation] {
        guard let cgImage = NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "ScreenLens", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: results)
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
    
    func translate(text: String, to target: String) async throws -> String {
        let source = Locale.Language(identifier: "en")
        let targetLang = Locale.Language(identifier: target)
        
        if #available(macOS 26.0, *) {
            let session = TranslationSession(installedSource: source, target: targetLang)
            let response = try await session.translate(text)
            return response.targetText
        } else {
            // Fallback: return original with note
            return "[macOS 26+ required] \(text)"
        }
    }
    
    func convertBoundingBox(_ box: CGRect, imageSize: CGSize) -> CGRect {
        // Vision: origin bottom-left, normalized. Convert to screen coordinates (origin bottom-left on macOS)
        let x = box.origin.x * imageSize.width
        let y = box.origin.y * imageSize.height
        let w = box.size.width * imageSize.width
        let h = box.size.height * imageSize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    func showAlert(_ message: String) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "ScreenLens"
            alert.informativeText = message
            alert.runModal()
        }
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
        
        // Semi-transparent background
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
            // Slightly pad the rect
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
