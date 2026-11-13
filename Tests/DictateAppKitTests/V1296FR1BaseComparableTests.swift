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

    // MARK: U8 (V-F10) — no no_input warning while the first native start has not returned

    @Test func no_input_warn_before_first_start() async throws {
        let blocked = Builtin(), gate = DispatchSemaphore(value: 0)
        blocked.startGate = gate
        let r = Rig([blocked]); try await r.start()
        #expect(await V.eventually { blocked.starts.value == 1 })
        #expect(!blocked.started)
        r.tick(100.1); r.tick(100.2); r.tick(100.5)
        let warns = r.recorder.builtinConversationDiagnostics.filter { $0 == "health=warn reason=no_input" }.count
        print("D \(Self.phase) no_input_warn_before_first_start warns=\(warns)")
        #expect(warns == 0)
        gate.signal()
        #expect(await V.eventually { r.verifiedStart(1) })
        await r.stop()
    }

    // MARK: U8 (V-F9) — first detection is `drift`; `failed` only when the re-bind failed

    @Test(arguments: [true, false]) func first_bind_detection_logs_drift(rebindOK: Bool) async throws {
        let first = Builtin(); first.readback.value = 999
        let second = Builtin(); if !rebindOK { second.readback.value = 999 }
        let r = Rig([first, second]); try await r.start()
        if rebindOK {
            #expect(await V.eventually { r.verifiedStart(2) })
        } else {
            #expect(await V.eventually { r.failures.value.map(\.reason) == [.builtinBindFailed] })
        }
        let binds = r.recorder.builtinConversationDiagnostics.filter { $0.hasPrefix("builtin_bind ") }
        let results = binds.map { $0.split(separator: " ")[1].replacingOccurrences(of: "result=", with: "") }
        print("D \(Self.phase) first_bind_detection_logs_drift rebind=\(rebindOK ? "ok" : "fails") results=\(results.joined(separator: ","))")
        #expect(binds.first == "builtin_bind result=drift from=999 to=81")
        #expect(results == (rebindOK ? ["drift", "rebound"] : ["drift", "failed"]))
        await r.stop()
    }

    /// The re-bind owns the full 300 ms from detection: a replacement whose start returns verified ~170 ms after
    /// detection (after 001c599's 150 ms timer, well inside 300 ms) is a `rebound`, not a failure.
    @Test func rebind_gets_full_300ms() async throws {
        let first = Builtin(); first.readback.value = 999
        let second = Builtin(), gate = DispatchSemaphore(value: 0)
        second.startGate = gate
        let r = Rig([first, second])
        try await r.start()
        #expect(await V.eventually { second.starts.value == 1 }) // detection happened before this point
        let observed = Self.uptime
        let released = V.Box<TimeInterval?>(nil)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.17) {
            released.value = ProcessInfo.processInfo.systemUptime
            gate.signal()
        }
        #expect(await Self.waitUntil(2) { released.value != nil })
        let releasedMs = Int(((released.value! - observed) * 1000).rounded())
        _ = await V.eventually { r.verifiedStart(2) || !r.failures.value.isEmpty }
        try? await Task.sleep(nanoseconds: 200_000_000) // past the 300 ms limit
        let failed = r.failures.value.count
        print("D \(Self.phase) rebind_gets_full_300ms rebind_returned_after_ms=\(releasedMs) failed=\(failed) rebound=\(r.verifiedStart(2) ? 1 : 0)")
        #expect(releasedMs >= 150 && releasedMs < 290) // the scenario itself: released between the two limits
        #expect(failed == 0)
        #expect(r.verifiedStart(2))
        await r.stop()
    }

    // MARK: U8 (V-F11) — a route change that lands inside an apply raises a generation when the apply ends

    @Test func apply_end_fingerprint_reread() async throws {
        let second = Builtin()
        let r = Rig([Builtin(), second]); try await r.start(); r.emit()
        second.afterStart = { [weak r] in
            guard let r else { return }
            r.routeFacts.update { $0.2.id = 99 }      // the input device changes while the apply waits
            r.recorder.observeConversationRoute()     // and its notification arrives during the apply
        }
        r.routeFacts.update { $0.1.id = 90 }
        r.recorder.observeConversationRoute()
        #expect(try r.recorder.reconfigureConversationInput(at: 100.1))
        let generation = r.recorder.activeRouteGeneration
        let pending = generation != r.recorder.activeAppliedRouteGeneration
        print("D \(Self.phase) apply_end_fingerprint_reread generation=\(generation) pending=\(pending ? 1 : 0)")
        #expect(generation == 2 && pending)
        #expect(r.states.value.last == .routeChangePending(generation: 2))
        await r.stop()
    }

    // MARK: V-F6 — the production timers and the real clock decide the first-audio verdict

    @Test(arguments: ["silent", "silent_first_audio_timer_only", "healthy"])
    func real_timer_first_audio(_ c: String) async throws {
        let r = Rig()
        let recorder = r.recorder
        recorder.builtinConversationAutomaticTimers = true
        recorder.builtinConversationClock = { ProcessInfo.processInfo.systemUptime }
        let verdict = V.Box<(BuiltinFirstAudioVerdict, TimeInterval)?>(nil)
        recorder.onBuiltinFirstAudio = { v in
            let now = ProcessInfo.processInfo.systemUptime
            verdict.update { if $0 == nil { $0 = (v, now) } }
        }
        if c == "silent_first_audio_timer_only" {
            try await recorder.startAsync(device: .builtIn) // no resetCapture: no health timer, only the first-audio timer
        } else {
            try await r.start() // host order: resetCapture (health clock) then start
        }
        let value: Float = c == "healthy" ? 0.1 : 0
        let feeder = Task {
            for _ in 0..<25 {
                if Task.isCancelled { break }
                r.units.value.last!.emit(Array(repeating: value, count: 2_400), at: ProcessInfo.processInfo.systemUptime)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        #expect(await Self.waitUntil(3) { verdict.value != nil })
        feeder.cancel()
        let clockNote = recorder.builtinConversationDiagnostics.first { $0.hasPrefix("builtin_first_audio_clock start=") }
        let t0 = Double(clockNote?.split(separator: "=").last ?? "0") ?? 0
        let (v, at) = try #require(verdict.value)
        let ms = Int((at * 1000 - t0).rounded())
        if c == "healthy" {
            print("D GREEN real_timer_first_audio_healthy=1 verdict=\(v.rawValue) at_ms=\(ms)")
            #expect(v == .ok)
        } else {
            print("D GREEN real_timer_first_audio=1 zeros_at_ms=\(ms) case=\(c) verdict=\(v.rawValue)")
            #expect(v == .zeros)
            #expect(ms >= 1_000 && ms <= 1_300)
        }
        await r.stop()
    }
}
