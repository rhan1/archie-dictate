import AppKit
import CoreGraphics
import Carbon
#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// Prefer explicit, unmodified Unicode events; borrow the clipboard only when preflight
/// rules out typing. Both paths require a complete new payload at the same AX destination.
public final class TextInserter {
    public enum Result: Equatable, Sendable { case confirmed, timedOut, held }
    public static let restoreDelay: TimeInterval = 1.0
    public static let defaultTimeout: TimeInterval = 10.0
    public static let defaultPollInterval: TimeInterval = 0.1
    private static let typingInterval: TimeInterval = 0.01

    private let keyEventPosting: KeyEventPosting
    private let typingEligibility: (() -> TypingEligibility)?
    private let pasteboard: NSPasteboard
    private var cancelActiveTyping: (() -> Void)?
    /// Recovery copy; a cancelled partial insertion retains only its unposted remainder.
    public private(set) var heldText: String?
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
        keyEventPosting: KeyEventPosting? = nil,
        typingEligibility: (() -> TypingEligibility)? = nil,
        schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
        pollInterval: TimeInterval = defaultPollInterval,
        timeout: TimeInterval = defaultTimeout,
        axReader: (() -> [String]?)? = nil,
        logger: ((String) -> Void)? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.keyEventPosting = keyEventPosting ?? postKeystroke.map(ClosureKeyEventPoster.init) ?? SystemKeyEventPoster()
        self.typingEligibility = typingEligibility
        self.pasteboard = pasteboard
        self.schedule = schedule ?? { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        self.pollInterval = max(0.01, pollInterval)
        self.timeout = max(0, timeout)
        self.now = now
        self.fakeReader = axReader
        self.log = logger ?? { AppController.note($0) }
    }

    /// Inserts `text` verbatim at the cursor of the frontmost app. `completion`
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

    /// Called on the main queue by the controller's existing Esc/cancel path.
    public func cancelTyping() {
        if Thread.isMainThread { cancelActiveTyping?() }
        else { DispatchQueue.main.async { self.cancelActiveTyping?() } }
    }

    private func eligibility(for element: AXUIElement?) -> TypingEligibility {
        if let typingEligibility { return typingEligibility() }
        // Injected AX readers and private pasteboards never reach system input/AX APIs.
        guard fakeReader == nil, pasteboard.name == NSPasteboard.general.name,
              Self.isAppRuntime() else { return .noFocus }
        if IsSecureEventInputEnabled() { return .secure }
        guard let element else { return .noFocus }
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        let role = attribute(kAXRoleAttribute) as? String
        let subrole = attribute(kAXSubroleAttribute) as? String
        if role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole { return .secure }
        guard attribute(kAXEnabledAttribute) as? Bool != false,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "") else { return .noFocus }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return .noFocus }
        return .editable
    }

    /// Character iteration preserves extended grapheme clusters, including surrogate pairs.
    /// An oversized cluster cannot satisfy both bounds and must use paste unchanged.
    private static func unicodeChunks(_ text: String) -> [[UInt16]]? {
        var chunks: [[UInt16]] = []
        var chunk: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            guard units.count <= 32 else { return nil }
            if chunk.count + units.count > 32 { chunks.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private func insertNext() {
        guard !inFlight, !pending.isEmpty else { return }
        inFlight = true
        heldText = nil
        let (text, shouldInsert, onResult, completion) = pending.removeFirst()
        let started = now()
        func finish(_ result: Result) {
            self.cancelActiveTyping = nil
            onResult?(result)
            completion?()
            self.inFlight = false
            self.insertNext()
        }
        if let shouldInsert, !shouldInsert() {
            heldText = text
            log("insertion=paste reason=focus_changed confirmed=0")
            finish(.held)
            return
        }
        if text.isEmpty {
            log("insertion=typed chars=0 events=0 ms=0 confirmed=1")
            finish(.confirmed)
            return
        }

        let initialElement: AXUIElement?
        let initialTexts: [String]
        if let fakeReader {
            initialElement = nil
            initialTexts = fakeReader() ?? []
        } else {
            initialElement = pasteboard.name == NSPasteboard.general.name ? currentFocusedElement() : nil
            initialTexts = initialElement.map(readAXTexts) ?? []
        }

        let chunks = Self.unicodeChunks(text)
        let reason: String?
        switch eligibility(for: initialElement) {
        case .secure: reason = "secure"
        case .noFocus: reason = "no_focus"
        case .editable:
            // A typed newline/control may submit a terminal prompt. Preserve it through paste.
            if text.unicodeScalars.contains(where: {
                [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            }) { reason = "control_chars" }
            else if chunks == nil { reason = "grapheme_too_long" }
            else { reason = nil }
        }
        let events = (chunks ?? []).flatMap { units in
            [InsertionKeyEvent(utf16: units, keyDown: true, flags: []),
             InsertionKeyEvent(utf16: units, keyDown: false, flags: [])]
        }
        // Preparing the entire batch is the final preflight. No event is posted yet.
        let pasteReason = reason ?? (keyEventPosting.prepare(events) ? nil : "events_unavailable")
        let deadline = started + timeout
        var saved: PasteboardSnapshot?
        var ourChangeCount: Int?
        var eventCount = 0
        var postedUnits = 0
        var cancelled = false
        var finished = false

        func complete(_ confirmed: Bool) {
            guard !finished else { return }
            finished = true
            if let pasteReason {
                if confirmed, let saved, let ourChangeCount {
                    saved.restore(to: self.pasteboard, ifUnchangedSince: ourChangeCount)
                }
                self.log(confirmed ? "paste_confirm=ax" : "paste_confirm=timeout")
                self.log("insertion=paste reason=\(pasteReason) confirmed=\(confirmed ? 1 : 0)")
            } else {
                self.log("insertion=typed chars=\(text.count) events=\(eventCount) ms=\(Int(max(0, self.now() - started) * 1000)) confirmed=\(confirmed ? 1 : 0)")
            }
            if !confirmed {
                // Never resend an ambiguous insertion. The controller exposes this recovery copy.
                self.heldText = cancelled && postedUnits < text.utf16.count
                    ? String(decoding: Array(text.utf16.dropFirst(postedUnits)), as: UTF16.self) : text
            }
            finish(confirmed ? .confirmed : .timedOut)
        }

        func checkConfirmed(_ currentTexts: [String]?) -> Bool {
            guard let current = currentTexts?.first else { return false }
            return Self.hasCompleteNewOccurrence(of: text, initial: initialTexts.first ?? "", current: current)
        }
        func pollStep() {
            guard !finished else { return }
            let current = self.sampleTexts(initialElement: initialElement)
            if cancelled { complete(false) }
            else if self.now() <= deadline, checkConfirmed(current) { complete(true) }
            else if self.now() >= deadline - 1e-6 { complete(false) }
            else {
                self.schedule(min(self.pollInterval, max(0, deadline - self.now())), pollStep)
            }
        }

        if pasteReason != nil {
            saved = PasteboardSnapshot.capture(pasteboard)
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
            item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
            pasteboard.writeObjects([item])
            ourChangeCount = pasteboard.changeCount
            keyEventPosting.postPaste()
            schedule(min(pollInterval, timeout), pollStep)
            return
        }

        cancelActiveTyping = { cancelled = true }
        func typeStep(_ index: Int) {
            guard !finished else { return }
            // A changed destination or secure input appearing mid-stream stops typing;
            // it never permits an automatic paste after an event has been posted.
            guard !cancelled, self.now() < deadline,
                  self.sampleTexts(initialElement: initialElement) != nil,
                  self.eligibility(for: initialElement) == .editable else {
                cancelled = true
                complete(false)
                return
            }
            self.keyEventPosting.postPreparedEvent(at: index)
            self.keyEventPosting.postPreparedEvent(at: index + 1)
            eventCount += 2
            postedUnits += events[index].utf16.count
            if index + 2 < events.count {
                self.schedule(Self.typingInterval) { typeStep(index + 2) }
            } else {
                self.schedule(min(self.pollInterval, max(0, deadline - self.now())), pollStep)
            }
        }
        typeStep(0)
    }

    /// H1b (v1.18): the COMPLETE payload must newly occur in the same attribute.
    /// Verbatim first; then, for terminals that hard-wrap and frame long input,
    /// the same complete payload with whitespace and box-drawing characters
    /// (U+2500-U+257F) ignored on both sides. A suffix, a last visible row, a
    /// length change or a clipboard change is never evidence.
    static func hasCompleteNewOccurrence(of text: String, initial: String, current: String) -> Bool {
        // Count complete new occurrences rather than a minimal string
        // diff (which trims shared letters from a real replacement).
        func occurrences(_ value: String, of needle: String) -> Int {
            value.components(separatedBy: needle).count - 1
        }
        if occurrences(current, of: text) > occurrences(initial, of: text) { return true }
        func normalized(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter {
                !$0.properties.isWhitespace && !(0x2500...0x257F).contains($0.value)
            }))
        }
        let payload = normalized(text)
        guard !payload.isEmpty else { return false }
        return occurrences(normalized(current), of: payload) > occurrences(normalized(initial), of: payload)
    }

    public static func postCommandV() {
        SystemKeyEventPoster().postPaste()
    }
}
