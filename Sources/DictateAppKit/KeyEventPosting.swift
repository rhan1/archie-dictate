import CoreGraphics

/// Immutable descriptions let tests inspect every event without creating or posting CGEvents.
public struct InsertionKeyEvent {
    public let utf16: [UInt16]
    public let keyDown: Bool
    public let flags: CGEventFlags

    public init(utf16: [UInt16], keyDown: Bool, flags: CGEventFlags) {
        self.utf16 = utf16
        self.keyDown = keyDown
        self.flags = flags
    }
}

public protocol KeyEventPosting: AnyObject {
    /// Prepare the entire batch before posting anything; failure permits a safe paste fallback.
    func prepare(_ events: [InsertionKeyEvent]) -> Bool
    func postPreparedEvent(at index: Int)
    func postPaste()
}

public enum TypingEligibility {
    case editable, noFocus, secure
}

/// Legacy paste-only injection stays safe for existing callers and R7/H1b fixtures.
final class ClosureKeyEventPoster: KeyEventPosting {
    let paste: () -> Void
    init(_ paste: @escaping () -> Void) { self.paste = paste }
    func prepare(_ events: [InsertionKeyEvent]) -> Bool { false }
    func postPreparedEvent(at index: Int) {}
    func postPaste() { paste() }
}

/// The only CGEvent posting boundary. Nothing is allocated until an app requests delivery.
final class SystemKeyEventPoster: KeyEventPosting {
    private var prepared: [CGEvent] = []

    func prepare(_ events: [InsertionKeyEvent]) -> Bool {
        prepared = []
        guard TextInserter.isAppRuntime(), let source = CGEventSource(stateID: .privateState) else { return false }
        for event in events {
            guard let key = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: event.keyDown) else {
                prepared = []
                return false
            }
            event.utf16.withUnsafeBufferPointer {
                key.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            // Never inherit physically held Option/Shift/Command from the trigger chord.
            key.flags = []
            prepared.append(key)
        }
        return true
    }

    func postPreparedEvent(at index: Int) {
        prepared[index].flags = []
        prepared[index].post(tap: .cghidEventTap)
    }

    func postPaste() {
        guard TextInserter.isAppRuntime(), let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
