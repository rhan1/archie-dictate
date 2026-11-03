import Testing
@testable import DictateCore

/// v1.28 B1: a transient HFP link is not a warm route (requirement 1), and a stopped engine is never owed
/// nothing while the dictation runs (requirement 2). Times in s after the start.
@Suite("V128HeadsetIOGuard")
struct V128HeadsetIOGuardTests {
    // MARK: Requirement 1 — the classification

    @Test func startRouteClassification() {
        #expect(HeadsetIOGuard.warmAfter == 2.0)
        #expect(HeadsetIOGuard.startRoute(hfp: false, sinceRelease: 0.1) == .transient)   // FR3-D: mid-flip link reads A2DP
        #expect(HeadsetIOGuard.startRoute(hfp: false, sinceRelease: 2.0) == .cold)
        #expect(HeadsetIOGuard.startRoute(hfp: false, sinceRelease: nil) == .cold)
        #expect(HeadsetIOGuard.startRoute(hfp: true, sinceRelease: 0.1) == .transient)       // f243a0c8
        #expect(HeadsetIOGuard.startRoute(hfp: true, sinceRelease: 1.999) == .transient)
        #expect(HeadsetIOGuard.startRoute(hfp: true, sinceRelease: 2.0) == .warm)
        #expect(HeadsetIOGuard.startRoute(hfp: true, sinceRelease: 5.0) == .warm)            // a genuine warm start
        #expect(HeadsetIOGuard.startRoute(hfp: true, sinceRelease: nil) == .warm)            // nothing of ours released it
    }

    @Test func transientIsNeverAlsoWarm() {
        let io = HeadsetIOGuard(bluetooth: true, warmRoute: true, transientRoute: true)
        #expect(io.warmRoute && !io.transientRoute)
        #expect(!HeadsetIOGuard(bluetooth: false, transientRoute: true).transientRoute)
    }

    /// The transient route keeps `engine_stopped`: a running notification neither opens a `format_changed`
    /// obligation nor relabels the open one (the warm route does both — control below).
    @Test func transientKeepsEngineStoppedThroughARunningNotification() {
        var io = HeadsetIOGuard(bluetooth: true, transientRoute: true)
        #expect(io.configurationChanged(at: 0.2, engineRunning: true) == .leaveRunning)   // no obligation opened
        #expect(io.obligation == nil)
        #expect(io.observe(at: 1.0, engineRunning: false) == .reattach)
        _ = io.configurationChanged(at: 1.05, engineRunning: true)
        #expect(io.obligation?.reason == .engineStopped)
    }

    @Test func warmRouteControlStillRelabels() {
        var io = HeadsetIOGuard(bluetooth: true, warmRoute: true)
        #expect(io.observe(at: 1.0, engineRunning: false) == .reattach)
        _ = io.configurationChanged(at: 1.05, engineRunning: true)
        #expect(io.obligation?.reason == .formatChanged)
    }

    /// Zeros from the re-attached client on a collapsing link are not IO back: the obligation stays owed and
    /// escalates at the bound (f243a0c8 `settled … silent_frames` → `escalate`). A cold route (control) still
    /// discharges on zeros, as in v1.12 (`observedFramesEndTheInFlightReattachEarly`).
    @Test func transientZerosDoNotDischargeTheReattach() {
        var io = HeadsetIOGuard(bluetooth: true, transientRoute: true)
        #expect(io.observe(at: 1.0, engineRunning: false) == .reattach)
        for step in 1...9 {
            let t = 1.0 + Double(step) * 0.1
            io.headsetFrames(2_400, peak: 0, at: t)
            #expect(io.observe(at: t, engineRunning: true) == .pending(until: 2.0))
        }
        #expect(io.observe(at: 2.0, engineRunning: true) == .escalate)
        #expect(io.obligation?.reason == .engineStopped)

        var cold = HeadsetIOGuard(bluetooth: true)
        #expect(cold.observe(at: 1.0, engineRunning: false) == .reattach)
        cold.headsetFrames(2_400, peak: 0, at: 1.1)
        #expect(cold.observe(at: 1.1, engineRunning: true) == .none && cold.obligation == nil)
    }

    @Test func transientSustainedSignalDischarges() {
        var io = HeadsetIOGuard(bluetooth: true, transientRoute: true)
        #expect(io.observe(at: 1.0, engineRunning: false) == .reattach)
        io.headsetFrames(2_400, peak: 0.3, at: 1.1)
        #expect(io.observe(at: 1.1, engineRunning: true) == .pending(until: 2.0))          // 100 ms: not sustained
        io.headsetFrames(2_400, peak: 0.3, at: 1.2)
        #expect(io.observe(at: 1.2, engineRunning: true) == .none && io.obligation == nil)
    }

    // MARK: Requirement 2 — never owed nothing for ever

    /// f243a0c8 on the 1.28 guard: stop → re-attach → zeros → escalate → restart → the fresh engine stops → a
    /// NEW obligation with its own re-attach (held while the restart is in flight), then IO.
    @Test func aStopOfTheRestartedEngineOpensANewObligation() {
        var io = HeadsetIOGuard(bluetooth: true, transientRoute: true)
        #expect(io.observe(at: 1.0, engineRunning: false) == .reattach)
        io.headsetFrames(2_400, peak: 0, at: 1.5)
        #expect(io.observe(at: 2.0, engineRunning: true) == .escalate)
        #expect(io.observe(at: 2.6, engineRunning: false) == .none)                         // the restart owns it
        io.restarted(at: 3.4)
        #expect(io.obligation == nil && io.obligationGeneration == 1)
        #expect(io.configurationChanged(at: 3.65, engineRunning: false) == .pending(until: 4.4))
        #expect(io.obligation?.reason == .engineStopped && io.obligationsOpened == 2)
        #expect(io.observe(at: 4.4, engineRunning: false) == .reattach)
        #expect(io.reattaches == 2)
        io.headsetFrames(2_400, peak: 0.3, at: 4.6)
        io.headsetFrames(1_200, peak: 0.3, at: 4.65)
        #expect(io.observe(at: 4.7, engineRunning: true) == .none && io.obligation == nil)
        #expect(io.heldNote == "io_held=1 config_notifications=1 io_obligations=2/2 io_obligation=none reattaches=2 io_generation=1")
    }

    /// RED twin of the above on the pre-1.28 rule: the escalated obligation answered `.none` for ever.
    @Test func anEscalatedObligationIsReofferedWhenNoRestartComes() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(io.observe(at: 1.0, engineRunning: false) == .reattach)
        #expect(io.observe(at: 2.0, engineRunning: false) == .escalate)
        var offeredAt: Double?
        for step in 1...60 {
            let t = 2.0 + Double(step) * 0.1
            let reaction = io.observe(at: t, engineRunning: false)
            if reaction == .reattach { offeredAt = t; break }
            #expect(reaction == .none)
        }
        #expect(offeredAt.map { abs($0 - (2.0 + HeadsetIOGuard.restartWait)) < 0.15 } == true)
        #expect(io.reattaches == 2 && io.obligationGeneration == 1)
    }

    /// Bounded: `maxReattaches` across generations, then `.exhausted` (never `.none`).
    @Test func newObligationsStayWithinTheReattachBudget() {
        var io = HeadsetIOGuard(bluetooth: true)
        var t = 1.0
        var given = 0
        for _ in 0..<5 {
            if io.configurationChanged(at: t, engineRunning: false) == .reattach { given += 1 }
            if io.observe(at: t + 1.0, engineRunning: false) == .escalate { io.restarted(at: t + 1.5) }
            t += 3.0
        }
        #expect(given == HeadsetIOGuard.maxReattaches)
        #expect(io.observe(at: t + 2, engineRunning: false) == .exhausted)
    }

    /// The episode refused for good (`reattachUnavailable`): `.exhausted`, never re-offered, and a restart that
    /// never came is not answered by `restarted`.
    @Test func episodeRefusalIsExhaustedNotReoffered() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(io.observe(at: 1.0, engineRunning: false) == .reattach)
        io.reattachUnavailable()
        for step in 1...80 { #expect(io.observe(at: 1.0 + Double(step) * 0.1, engineRunning: false) == .exhausted) }
        io.restarted(at: 9.5)
        #expect(io.obligation != nil && io.obligationGeneration == 0)
    }

    /// A bridge zero-run restart with no escalated obligation owes the guard nothing (no-op).
    @Test func restartWithoutEscalationIsANoOp() {
        var io = HeadsetIOGuard(bluetooth: true)
        io.restarted(at: 1.0)
        #expect(io.allows(at: 1.01) && io.obligationGeneration == 0)
        #expect(io.heldNote == "io_held=0 config_notifications=0 io_obligations=0/0 io_obligation=none reattaches=0")
    }
}
