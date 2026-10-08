import Foundation

public enum KeyCodes {
    public static let leftOption: UInt16 = 58
    public static let rightOption: UInt16 = 61
    public static let escape: UInt16 = 53
}

public enum ModifierMask {
    public static let leftOptionDevice: UInt64 = 0x20
    public static let rightOptionDevice: UInt64 = 0x40
    public static let alternate: UInt64 = 0x80000
    public static let shift: UInt64 = 0x20000
    public static let control: UInt64 = 0x40000
    public static let command: UInt64 = 0x100000
    public static let function: UInt64 = 0x800000
}

public enum KeyEvent: Equatable, Sendable {
    case flagsChanged(keyCode: UInt16, flags: UInt64, time: TimeInterval)
    case keyDown(keyCode: UInt16, time: TimeInterval)
}

public enum TapSignal: Equatable, Sendable { case none, tap, doubleTap }

public struct DoubleTapDetector: Sendable {
    public static let defaultWindow: TimeInterval = 0.35
    public static let defaultMaxHold: TimeInterval = 0.35
    public let window: TimeInterval
    public let maxHold: TimeInterval
    private var pressTime: TimeInterval?
    private var firstRelease: TimeInterval?
    private var invalidUntilRelease = false

    public init(window: TimeInterval = DoubleTapDetector.defaultWindow,
                maxHold: TimeInterval = DoubleTapDetector.defaultMaxHold) {
        self.window = window
        self.maxHold = maxHold
    }

    /// v1.0 API: true exactly when this event completes a double-tap.
    public mutating func handle(_ event: KeyEvent) -> Bool {
        process(event) == .doubleTap
    }

    /// v1.1: every clean Left-Option tap is reported (`.tap`), and the second
    /// one inside the window as `.doubleTap` instead. Chords, holds, Right
    /// Option and other modifiers report `.none`.
    public mutating func process(_ event: KeyEvent) -> TapSignal {
        guard case let .flagsChanged(keyCode, flags, time) = event,
              keyCode == KeyCodes.leftOption, time.isFinite else {
            reset()
            return .none
        }
        let pressed = flags & ModifierMask.leftOptionDevice != 0
        let forbidden = ModifierMask.shift | ModifierMask.control |
            ModifierMask.command | ModifierMask.function
        guard flags & forbidden == 0 else {
            reset()
            invalidUntilRelease = pressed
            return .none
        }
        if pressed {
            guard pressTime == nil, !invalidUntilRelease else {
                reset()
                invalidUntilRelease = true
                return .none
            }
            pressTime = time
            return .none
        }
        guard !invalidUntilRelease, let start = pressTime,
              time >= start, time - start <= maxHold else {
            reset()
            return .none
        }
        pressTime = nil
        if let firstRelease, start >= firstRelease, start - firstRelease <= window {
            reset()
            return .doubleTap
        }
        firstRelease = time
        return .tap
    }

    public mutating func reset() {
        pressTime = nil
        firstRelease = nil
        invalidUntilRelease = false
    }
}
