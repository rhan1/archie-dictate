import AppKit
import DictateCore

/// D6: menu-bar mic. No settings UI.
public final class StatusItemController: NSObject {
    public var onToggle: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    public override init() {
        super.init()
        setRecording(false)
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Dictate (double-tap ⌥)", action: #selector(toggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let openLog = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    public func setRecording(_ recording: Bool) {
        let name = recording ? "mic.fill" : "mic"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Dictate")
        image?.isTemplate = true
        item.button?.image = image
    }

    @objc private func toggle() { onToggle?() }

    @objc private func openLog() {
        let url = DictationLog.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }
}
