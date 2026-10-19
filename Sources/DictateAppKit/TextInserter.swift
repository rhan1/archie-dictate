import AppKit
import CoreGraphics
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// D3: borrow the clipboard, synthesize ⌘V, then put the clipboard back.
/// D1 (v1.15): restore old clipboard only after inserted text is confirmed in the SAME initially
/// focused accessibility element via an AXValue / AXSelectedText insertion delta.
public final class TextInserter {
    public enum Result: Equatable, Sendable { case confirmed, timedOut, held }
    public static let restoreDelay: TimeInterval = 1.0
    public static let defaultTimeout: TimeInterval = 10.0
    public static let defaultPollInterval: TimeInterval = 0.1
    private static let vKeyCode: CGKeyCode = 9

    private let pasteboard: NSPasteboard
    private let postKeystroke: () -> Void
    // Accessed only on the main queue, including reentrant completion calls.
    private var pending: [(text: String, shouldInsert: (() -> Bool)?, result: ((Result) -> Void)?, completion: (() -> Void)?)] = []
    private var inFlight = false
    /// Runs `work` on the main queue after a delay (v1.12: injectable so tests run on a manual clock).
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval
    private let fakeReader: (() -> [String]?)?
    private let log: (String) -> Void
    private let now: () -> TimeInterval

    public init(
        pasteboard: NSPasteboard = .general,
        postKeystroke: (() -> Void)? = nil,
        schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
        pollInterval: TimeInterval = defaultPollInterval,
        timeout: TimeInterval = defaultTimeout,
        axReader: (() -> [String]?)? = nil,
        logger: ((String) -> Void)? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.pasteboard = pasteboard
        self.postKeystroke = postKeystroke ?? TextInserter.postCommandV
        self.schedule = schedule ?? { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        self.pollInterval = max(0.01, pollInterval)
        self.timeout = max(0, timeout)
        self.now = now
        self.fakeReader = axReader
        self.log = logger ?? { AppController.note($0) }
    }

    /// Pastes `text` verbatim at the cursor of the frontmost app. `completion`
    /// runs on the main queue after the restore window (a newer copy is kept).
    /// `shouldInsert` runs when this request reaches the head of the queue,
    /// before borrowing the clipboard, so callers can recheck the destination.
    public func insert(_ text: String, shouldInsert: (() -> Bool)? = nil, onResult: ((Result) -> Void)? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            self.pending.append((text, shouldInsert, onResult, completion))
            self.insertNext()
        }
    }

    /// Production permission prompting/AX reads may happen only when Bundle.main.bundleURL
    /// is an .app and executableURL is within Contents/MacOS of that same bundle.
    /// Pure, so it can be tested directly and fails closed outside an app bundle.
    public static func isAppRuntime(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL
    ) -> Bool {
        let bundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard bundle.pathExtension == "app" || bundle.path.hasSuffix(".app"),
              let executable = executableURL?.standardizedFileURL.resolvingSymlinksInPath() else {
            return false
        }
        let macosDir = bundle.appendingPathComponent("Contents/MacOS").standardizedFileURL.resolvingSymlinksInPath()
        let macosPath = macosDir.path.hasSuffix("/") ? macosDir.path : macosDir.path + "/"
        return executable.path.hasPrefix(macosPath)
    }

    private func currentFocusedElement() -> AXUIElement? {
        guard Self.isAppRuntime() else { return nil }
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
        return texts
    }

    private func sampleTexts(initialElement: AXUIElement?) -> [String]? {
        if let fakeReader {
            return fakeReader()
        }
        guard let initialElement, let current = currentFocusedElement(), CFEqual(initialElement, current) else {
            return nil
        }
        return readAXTexts(from: current)
    }

    private func insertNext() {
        guard !inFlight, !pending.isEmpty else { return }
        inFlight = true
        let (text, shouldInsert, onResult, completion) = pending.removeFirst()
        if let shouldInsert, !shouldInsert() {
            onResult?(.held)
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
            onResult?(.confirmed)
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
            initialElement = pasteboard.name == NSPasteboard.general.name ? currentFocusedElement() : nil
            if let initialElement {
                initialTexts = readAXTexts(from: initialElement)
            } else {
                initialTexts = []
            }
        }

        postKeystroke()
        let deadline = now() + timeout

        func checkConfirmed(currentTexts: [String]?) -> Bool {
            guard let currentTexts else { return false }
            // Compare each AX attribute against its own baseline. An old suffix
            // plus an unrelated edit is not evidence that this paste landed.
            for (index, current) in currentTexts.prefix(1).enumerated() {
                let initial = index < initialTexts.count ? initialTexts[index] : ""
                // Count complete new occurrences rather than a minimal string
                // diff (which trims shared letters from a real replacement).
                func occurrences(_ value: String, of needle: String) -> Int {
                    value.components(separatedBy: needle).count - 1
                }
                if occurrences(current, of: text) > occurrences(initial, of: text) { return true }

                // Terminals may hard-wrap and frame AXValue rows, or expose
                // only the visible tail. Ignore presentation characters, but
                // still require a new occurrence against the same baseline.
                func normalized(_ value: String) -> String {
                    String(String.UnicodeScalarView(value.unicodeScalars.filter {
                        !$0.properties.isWhitespace && !(0x2500...0x257F).contains($0.value)
                    }))
                }
                let payload = normalized(text)
                guard !payload.isEmpty else { continue }
                let currentValue = normalized(current)
                let initialValue = normalized(initial)
                if occurrences(currentValue, of: payload) > occurrences(initialValue, of: payload) { return true }
                let tail = String(payload.suffix(48))
                if occurrences(currentValue, of: tail) > occurrences(initialValue, of: tail) { return true }
            }
            return false
        }

        func pollStep() {
            let currentTexts = self.sampleTexts(initialElement: initialElement)
            if self.now() <= deadline, checkConfirmed(currentTexts: currentTexts) {
                saved.restore(to: self.pasteboard, ifUnchangedSince: ourChangeCount)
                self.log("paste_confirm=ax")
                onResult?(.confirmed)
                completion?()
                self.inFlight = false
                self.insertNext()
            } else if self.now() >= deadline - 1e-6 {
                // Timeout: do NOT restore; retain dictation so manual command V can recover
                self.log("paste_confirm=timeout")
                onResult?(.timedOut)
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
