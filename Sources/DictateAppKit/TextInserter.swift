import AppKit
import CoreGraphics

/// D3: borrow the clipboard, synthesize ⌘V, then put the clipboard back.
public final class TextInserter {
    public static let restoreDelay: TimeInterval = 1.0
    private static let vKeyCode: CGKeyCode = 9

    private let pasteboard: NSPasteboard
    private let postKeystroke: () -> Void
    // Accessed only on the main queue, including reentrant completion calls.
    private var pending: [(text: String, shouldInsert: (() -> Bool)?, completion: (() -> Void)?)] = []
    private var inFlight = false
    /// Runs `work` on the main queue after a delay (v1.12: injectable so tests run on a manual clock).
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    public init(pasteboard: NSPasteboard = .general, postKeystroke: (() -> Void)? = nil,
                schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        self.pasteboard = pasteboard
        self.postKeystroke = postKeystroke ?? TextInserter.postCommandV
        self.schedule = schedule ?? { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// Pastes `text` verbatim at the cursor of the frontmost app. `completion`
    /// runs on the main queue after the restore window (a newer copy is kept).
    /// `shouldInsert` runs when this request reaches the head of the queue,
    /// before borrowing the clipboard, so callers can recheck the destination.
    public func insert(_ text: String, shouldInsert: (() -> Bool)? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            self.pending.append((text, shouldInsert, completion))
            self.insertNext()
        }
    }

    private func insertNext() {
        guard !inFlight, !pending.isEmpty else { return }
        inFlight = true
        let (text, shouldInsert, completion) = pending.removeFirst()
        if let shouldInsert, !shouldInsert() {
            completion?()
            inFlight = false
            insertNext()
            return
        }
        let saved = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount
        postKeystroke()
        schedule(TextInserter.restoreDelay) {
            saved.restore(to: self.pasteboard, ifUnchangedSince: ourChangeCount)
            completion?()
            self.inFlight = false
            self.insertNext()
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
