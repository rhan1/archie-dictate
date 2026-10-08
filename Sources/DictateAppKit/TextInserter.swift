import AppKit
import CoreGraphics

/// D3: borrow the clipboard, synthesize ⌘V, then put the clipboard back.
public final class TextInserter {
    public static let restoreDelay: TimeInterval = 0.4
    private static let vKeyCode: CGKeyCode = 9

    private let pasteboard: NSPasteboard
    private let postKeystroke: () -> Void

    public init(pasteboard: NSPasteboard = .general, postKeystroke: (() -> Void)? = nil) {
        self.pasteboard = pasteboard
        self.postKeystroke = postKeystroke ?? TextInserter.postCommandV
    }

    /// Pastes `text` verbatim at the cursor of the frontmost app. `completion`
    /// runs on the main queue after the original clipboard has been restored.
    public func insert(_ text: String, completion: (() -> Void)? = nil) {
        let saved = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postKeystroke()
        DispatchQueue.main.asyncAfter(deadline: .now() + TextInserter.restoreDelay) { [pasteboard] in
            saved.restore(to: pasteboard)
            completion?()
        }
    }

    public static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
