import AppKit
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// D3: borrow the clipboard, synthesize ⌘V, then put the clipboard back.
/// D1 (v1.15): restore old clipboard only after inserted text is confirmed in the SAME initially
/// focused accessibility element via AXValue / AXSelectedText (last 40 characters of dictation).
public final class TextInserter {
    public static let restoreDelay: TimeInterval = 1.0
    public static let defaultTimeout: TimeInterval = 10.0
    public static let defaultPollInterval: TimeInterval = 0.1
    private static let vKeyCode: CGKeyCode = 9

    private let pasteboard: NSPasteboard
    private let postKeystroke: () -> Void
    // Accessed only on the main queue, including reentrant completion calls.
    private var pending: [(text: String, shouldInsert: (() -> Bool)?, completion: (() -> Void)?)] = []
    private var inFlight = false
    /// Runs `work` on the main queue after a delay (v1.12: injectable so tests run on a manual clock).
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval
    private let fakeReader: (() -> [String]?)?
    private let log: (String) -> Void

    public init(
        pasteboard: NSPasteboard = .general,
        postKeystroke: (() -> Void)? = nil,
        schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
        pollInterval: TimeInterval = defaultPollInterval,
        timeout: TimeInterval = defaultTimeout,
        axReader: (() -> [String]?)? = nil,
        logger: ((String) -> Void)? = nil
    ) {
        self.pasteboard = pasteboard
        self.postKeystroke = postKeystroke ?? TextInserter.postCommandV
        self.schedule = schedule ?? { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.fakeReader = axReader
        self.log = logger ?? { AppController.note($0) }
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

    private func currentFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    private func readAXTexts(from element: AXUIElement) -> [String] {
        var texts: [String] = []
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success, let valueRef {
            if let str = valueRef as? String {
                texts.append(str)
            } else if let attr = valueRef as? NSAttributedString {
                texts.append(attr.string)
            }
        }
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success, let selectedRef {
            if let str = selectedRef as? String {
                texts.append(str)
            } else if let attr = selectedRef as? NSAttributedString {
                texts.append(attr.string)
            }
        }
        return texts
    }

    private func sampleTexts(initialElement: AXUIElement?) -> [String]? {
        if let fakeReader {
            return fakeReader()
        }
        guard let initialElement, let current = currentFocusedElement(), CFEqual(initialElement, current).boolValue else {
            return nil
        }
        return readAXTexts(from: current)
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

        if text.isEmpty {
            saved.restore(to: pasteboard, ifUnchangedSince: ourChangeCount)
            completion?()
            inFlight = false
            insertNext()
            return
        }

        let initialElement: AXUIElement?
        let initialTexts: [String]
        if fakeReader != nil {
            initialElement = nil
            initialTexts = fakeReader!() ?? []
        } else {
            initialElement = currentFocusedElement()
            if let initialElement {
                initialTexts = readAXTexts(from: initialElement)
            } else {
                initialTexts = []
            }
        }

        let needle = String(text.suffix(40))
        let initialHadNeedle = !needle.isEmpty && initialTexts.contains(where: { $0.contains(needle) })

        postKeystroke()

        var elapsed: TimeInterval = 0.0

        func checkConfirmed(currentTexts: [String]?) -> Bool {
            guard let currentTexts, !needle.isEmpty else { return false }
            let hasNeedle = currentTexts.contains(where: { $0.contains(needle) })
            guard hasNeedle else { return false }
            if initialHadNeedle {
                return currentTexts != initialTexts
            }
            return true
        }

        func pollStep() {
            elapsed += self.pollInterval
            let currentTexts = self.sampleTexts(initialElement: initialElement)
            if checkConfirmed(currentTexts: currentTexts) {
                saved.restore(to: self.pasteboard, ifUnchangedSince: ourChangeCount)
                self.log("paste_confirm=ax")
                completion?()
                self.inFlight = false
                self.insertNext()
            } else if elapsed >= self.timeout - 1e-6 {
                // Timeout: do NOT restore; retain dictation so manual command V can recover
                self.log("paste_confirm=timeout")
                completion?()
                self.inFlight = false
                self.insertNext()
            } else {
                self.schedule(self.pollInterval) {
                    pollStep()
                }
            }
        }

        schedule(pollInterval) {
            pollStep()
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
