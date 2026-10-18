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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon
        
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
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
    
    func setupHotKeys() {
        // ⌥⌘T = option + command + T
        translateHotKey = HotKey(key: .t, modifiers: [.option, .command])
        translateHotKey?.keyDownHandler = { [weak self] in
            self?.translateScreen()
        }
        
        // ⌥⌘S = option + command + S
        searchHotKey = HotKey(key: .s, modifiers: [.option, .command])
        searchHotKey?.keyDownHandler = { [weak self] in
            self?.selectAndSearch()
        }
    }
    
    @objc func translateScreen() {
        Task {
            await performTranslate()
        }
    }
    
    @objc func selectAndSearch() {
        Task {
            await performSearch()
        }
    }
    
    func performTranslate() async {
        // TODO: capture → OCR with boxes → translate → overlay
        print("Translate triggered")
        // Placeholder: show a simple alert for now
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Translate Screen"
            alert.informativeText = "Overlay translation coming next. Capture + OCR + draw in place."
            alert.runModal()
        }
    }
    
    func performSearch() async {
        print("Search triggered")
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Select & Search"
            alert.informativeText = "Region select + Google search coming next."
            alert.runModal()
        }
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
