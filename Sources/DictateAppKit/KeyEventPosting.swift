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
