import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// archie-v73-fr1 Lane D: U7, U8 (V-F9, V-F10, V-F11) and the real-timer first-audio proof (V-F6).
/// Uses only the 001c599 rig API, so the SAME source runs against 001c599 production code for the REDs.
@Suite("V1296FR1BaseComparable", .serialized)
struct V1296FR1BaseComparableTests {
    typealias V = V1296BuiltinConversationTests
    typealias Rig = V1296BuiltinConversationTests.Rig
    typealias Builtin = V1296BuiltinConversationTests.Builtin
    static var phase: String { V.phase }
    static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    static var queueLabel: String { String(cString: __dispatch_queue_get_label(nil)) }
    static func waitUntil(_ seconds: Double, _ check: () -> Bool) async -> Bool {
        let end = uptime + seconds
        while uptime < end {
            if check() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return check()
    }

    // MARK: U7 (V-F8) — REAL timers. stop() lands after the handler's token check and before its evaluation
    // takes the lock (the production clock call between the two is the injection point).

    @Test func first_audio_timer_spins_after_stop() async throws {
        let r = Rig()
        let recorder = r.recorder
        let stopped = V.Box(false), runsAfterStop = V.Box(0)
        recorder.builtinConversationAutomaticTimers = true
        recorder.builtinConversationClock = { [weak recorder] in
            let now = ProcessInfo.processInfo.systemUptime
            // No health timer exists (no resetCapture): on this queue only the first-audio timer reads the clock.
            guard Self.queueLabel == "dictate.capture.health" else { return now }
            if stopped.value { runsAfterStop.update { $0 += 1 } } else {
                stopped.value = true
                _ = recorder?.stop()
            }
            return now
        }
        try await recorder.startAsync(device: .builtIn)
        #expect(await Self.waitUntil(3) { stopped.value })
        try? await Task.sleep(nanoseconds: 300_000_000)
        let runs = runsAfterStop.value
        print("D \(Self.phase) first_audio_timer_spins_after_stop handler_runs_after_stop=\(runs)")
        #expect(runs == 0)
        #expect(await recorder.awaitRelease() == .released)
    }
}
