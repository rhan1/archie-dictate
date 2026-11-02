import Foundation
import Testing
@testable import DictateCore

/// v1.27 B1 rules 2–4, pure (no recorder, no hardware).
@Suite("V127BuiltinWatch")
struct V127BuiltinWatchTests {
    @Test func unreadablePropertyIsNotDrift() {
        struct Unreadable: Error {}
        let check = BuiltinPin.enforce(expected: 81, read: { throw Unreadable() }, write: { _ in })
        #expect(check == .unreadable && check.note == "bridge_device_check=unreadable")
        // A readable mismatch the write could not correct keeps v1.8's drift semantics.
        let drift = BuiltinPin.enforce(expected: 81, read: { 152 }, write: { _ in throw Unreadable() })
        #expect(drift == .drift(from: 152) && drift.note == "bridge_device_check=drift from=152 fixed=0")
    }

    @Test func verdicts() {
        #expect(BuiltinWatch.judge(nil, headsetStarting: true, rebuilt: false) == BuiltinWatch.Verdict.none)
        #expect(BuiltinWatch.judge(.ok, headsetStarting: true, rebuilt: false) == BuiltinWatch.Verdict.none)
        #expect(BuiltinWatch.judge(.unreadable, headsetStarting: true, rebuilt: false) == .recheck)
        #expect(BuiltinWatch.judge(.unreadable, headsetStarting: false, rebuilt: true) == .recheck)
        #expect(BuiltinWatch.judge(.drift(from: 154), headsetStarting: true, rebuilt: false) == .rebuild(.drift))
        #expect(BuiltinWatch.judge(.drift(from: 154), headsetStarting: true, rebuilt: true) == .dead(.drift))
        #expect(BuiltinWatch.judge(.drift(from: 154), headsetStarting: false, rebuilt: false) == .dead(.drift))
        #expect(BuiltinWatch.judge(problem: .lost, headsetStarting: true, rebuilt: false) == .rebuild(.lost))
        #expect(BuiltinWatch.judge(problem: .lost, headsetStarting: true, rebuilt: true) == .dead(.lost))
    }

    /// Nothing ever delivered; the time `mic_dead` fires (nil: never within 6 s).
    private func failAt(bluetooth: Bool, inFlightUntil: TimeInterval?, builtinUsefulUntil: TimeInterval? = nil) -> (TimeInterval?, String) {
        var health = CaptureHealth()
        health.bluetooth = bluetooth
        health.recordingStarted(at: 0)
        health.sourceStarted(.builtin, at: 0)
        health.sourceStarted(.headset, at: 0)
        if inFlightUntil != nil { health.headsetStart(inFlight: true) }
        var t = 0.0
        while t < 6 {
            t = ((t + 0.1) * 10).rounded() / 10
            if let until = inFlightUntil, t >= until { health.headsetStart(inFlight: false) }
            if let useful = builtinUsefulUntil, t <= useful {
                health.buffer(.builtin, at: t, frames: 2_400, peak: 0.3)
                health.kept(at: t, peak: 0.3)
            }
            for action in health.tick(at: t, carrying: .builtin) {
                if case .fail = action { return (t, health.summary(at: t)) }
            }
        }
        return (nil, "")
    }

    @Test func bluetoothDeadlineWaitsForTheHeadsetStartUpTo4s() {
        print("B1 LITERAL rule4 constants failAfter=\(CaptureHealth.failAfter) bluetoothNoInputCap=\(CaptureHealth.bluetoothNoInputCap)")
        #expect(CaptureHealth.failAfter == 2.0 && CaptureHealth.bluetoothNoInputCap == 4.0)
        // Bluetooth, start in flight past the cap: mic_dead at 4.0 s, with sources.
        let stuck = failAt(bluetooth: true, inFlightUntil: 10)
        #expect(stuck.0 == 4.0 && stuck.1 == "builtin:dead,headset:dead")
        // Bluetooth, nothing delivered, start returned early: still the 4.0 s cap.
        #expect(failAt(bluetooth: true, inFlightUntil: 0.5).0 == 4.0)
        // Non-Bluetooth keeps 2.0 s.
        #expect(failAt(bluetooth: false, inFlightUntil: nil).0 == 2.0)
        #expect(failAt(bluetooth: false, inFlightUntil: 10).0 == 2.0)
        // Bluetooth after a useful delivery: v1.8's absolute deadline unless a re-attach is in flight.
        #expect(failAt(bluetooth: true, inFlightUntil: nil, builtinUsefulUntil: 0.4).0 == 2.4)
        #expect(failAt(bluetooth: true, inFlightUntil: 10, builtinUsefulUntil: 0.4).0 == 4.0)
    }

    @Test func headsetStartingUntilItsFirstBuffer() {
        var health = CaptureHealth()
        health.recordingStarted(at: 0)
        health.sourceStarted(.headset, at: 0)
        #expect(health.headsetStarting(at: 0.5))
        #expect(!health.headsetStarting(at: 2.5))                       // past its 2.0 s grace
        health.headsetStart(inFlight: true)
        #expect(health.headsetStarting(at: 2.5))                        // a start still in flight
        health.buffer(.headset, at: 2.6, frames: 480, peak: 0)
        #expect(!health.headsetStarting(at: 2.6))                       // delivering (even zeros): it can be judged
    }
}
