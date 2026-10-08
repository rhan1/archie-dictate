// QA helper: posts synthetic key events through the HID tap so Dictate's
// listen-only event tap sees them exactly like real keystrokes.
//   post-keys double   -> Left-Option double-tap (press/release x2, ~150 ms apart)
//   post-keys slow     -> two Left-Option taps 600 ms apart (must NOT trigger)
//   post-keys tap      -> ONE Left-Option tap (v1.1 finish)
//   post-keys esc      -> Escape
// The posting process needs Accessibility (run from the Warp tab that has it).
import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)

func option(down: Bool) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: down) else { return }
    e.type = .flagsChanged
    e.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20) : CGEventFlags(rawValue: 0)
    e.post(tap: .cghidEventTap)
}

func tap() {
    option(down: true)
    usleep(60_000)
    option(down: false)
}

switch CommandLine.arguments.dropFirst().first ?? "double" {
case "slow":
    tap(); usleep(600_000); tap()
case "tap":
    tap()
case "esc":
    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
default:
    tap(); usleep(150_000); tap()
}
usleep(50_000)
