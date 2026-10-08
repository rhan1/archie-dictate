import AppKit
import CoreGraphics
import DictateCore

/// D1: a listen-only CGEventTap on flagsChanged + keyDown. It never swallows an
/// event; it only feeds the pure DoubleTapDetector and reports Esc.
public final class HotkeyMonitor {
    public var onDoubleTap: (() -> Void)?
    public var onEscape: (() -> Void)?

    private var detector = DoubleTapDetector()
    /// QA only: traces Option flagsChanged events (never ordinary keystrokes).
    private let traceModifiers = ProcessInfo.processInfo.environment["DICTATE_TRACE"] == "1"
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    /// Returns false when macOS refuses the tap (no Accessibility / Input Monitoring grant).
    @discardableResult
    public func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            detector.reset()
        case .flagsChanged, .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let time = TimeInterval(event.timestamp) / 1_000_000_000
            let keyEvent: KeyEvent = type == .flagsChanged
                ? .flagsChanged(keyCode: keyCode, flags: event.flags.rawValue, time: time)
                : .keyDown(keyCode: keyCode, time: time)
            if traceModifiers, type == .flagsChanged, keyCode == KeyCodes.leftOption || keyCode == KeyCodes.rightOption {
                FileHandle.standardError.write(Data("option key=\(keyCode) flags=0x\(String(event.flags.rawValue, radix: 16)) t=\(time)\n".utf8))
            }
            if type == .keyDown, keyCode == KeyCodes.escape {
                onEscape?()
            }
            if detector.handle(keyEvent) {
                onDoubleTap?()
            }
        default:
            break
        }
    }
}
