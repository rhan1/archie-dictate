import Testing
@testable import DictateCore

/// v1.10 L1 → v1.12 L2: recovery anchored to observed IO state (GPT-6 review §A 1–2, §F
/// "Capture/lease" and "Source evidence" rows). v1.10's blind window is `HeadsetIOGuardV110`.
@Suite("HeadsetIOGuard")
struct HeadsetIOGuardTests {
    /// One run of a guard over a timeline: notifications, 100 ms health ticks, headset frames.
    /// `ticks` observe the engine as stopped from `stopsAt`; frames arrive only from `framesFrom`.
    struct Script {
        var notifications: [(at: Double, running: Bool)]
        var stopsAt: Double = .infinity
        var framesFrom: Double = .infinity
        var framePeak: Float = 0.3
        var until: Double = 3.0
    }
    struct Trace: Equatable { var reattaches: [Double] = []; var escalations: [Double] = [] }

    static func run(_ script: Script, io: inout HeadsetIOGuard) -> Trace {
        var trace = Trace()
        var events: [(Double, Int)] = script.notifications.indices.map { (script.notifications[$0].at, $0) }
        var tick = 0.1
        while tick <= script.until + 1e-9 { events.append((tick, -1)); tick += 0.1 }
        events.sort { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 > $1.1) }
        for (time, index) in events {
            if time >= script.framesFrom { io.headsetFrames(2_400, peak: script.framePeak, at: time) }
            let reaction: HeadsetIOGuard.Reaction
            if index >= 0 {
                reaction = io.configurationChanged(at: time, engineRunning: script.notifications[index].running)
            } else {
                reaction = io.observe(at: time, engineRunning: time < script.stopsAt)
            }
            if reaction == .reattach { trace.reattaches.append((time * 1000).rounded() / 1000) }
            if reaction == .escalate { trace.escalations.append((time * 1000).rounded() / 1000) }
        }
        return trace
    }

    /// The same notifications through v1.10's guard (it has no observation input).
    static func runV110(_ script: Script) -> [Double] {
        var io = HeadsetIOGuardV110(bluetooth: true)
        return script.notifications.compactMap { note in
            io.configurationChanged(at: note.at, engineRunning: note.running) == .reattach ? note.at : nil
        }
    }

    // MARK: The review's literal inputs

    /// "config running at 0 ms; auto-stop at 200 ms; no frames thereafter" → bounded recovery
    /// attempted once, obligation visible. v1.10: the auto-stop's notification lands in the window
    /// (`handsOff`) and nothing ever re-attaches.
    static let autoStopAt200 = Script(notifications: [(0, true), (0.2, false)], stopsAt: 0.2)

    @Test func runningAt0AutoStopAt200NoFramesReattachesOnceV112Green() {
        var io = HeadsetIOGuard(bluetooth: true)
        let trace = Self.run(Self.autoStopAt200, io: &io)
        #expect(trace.reattaches == [0.2])                       // once, at the stop
        #expect(trace.escalations == [1.2])                      // no IO within the bound: one restart request
        #expect(io.obligation?.reason == .engineStopped)         // still owed IO: visible
        #expect(io.heldNote == "io_held=0 config_notifications=2 io_obligations=1/0 io_obligation=open:engine_stopped reattaches=1")
        #expect(io.framework == 1)
    }

    @Test func runningAt0AutoStopAt200NoFramesV110Red() {
        #expect(Self.runV110(Self.autoStopAt200).isEmpty)        // v1.10: no re-attach at all
    }

    /// The review's hole: a SECOND stopped-engine notification inside v1.10's window.
    static let secondStop = Script(notifications: [(10.242, false), (10.6, false)], framesFrom: 10.4, until: 11.5)

    @Test func secondStoppedNotificationGetsItsReattachV112Green() {
        var io = HeadsetIOGuard(bluetooth: true)
        let trace = Self.run(Self.secondStop, io: &io)
        #expect(trace.reattaches == [10.242, 10.6])
        #expect(io.obligationsOpened == 2 && io.obligationsDischarged == 2)
        #expect(io.obligation == nil)
    }

    @Test func secondStoppedNotificationV110Red() {
        #expect(Self.runV110(Self.secondStop) == [10.242])       // the second stop is swallowed
    }

    // MARK: State, not a window

    @Test func observedFramesEndTheInFlightReattachEarly() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(io.configurationChanged(at: 1.0, engineRunning: false) == .reattach)
        #expect(!io.allows(at: 1.1))
        io.headsetFrames(1_024, peak: 0, at: 1.13)               // IO is back (zeros still count as IO)
        #expect(io.observe(at: 1.2, engineRunning: true) == .none)
        #expect(io.allows(at: 1.2) && io.obligation == nil)       // v1.10 would hold until 2.0
    }

    @Test func aStopSeenOnlyByThePollOpensAnObligation() {
        var io = HeadsetIOGuard(bluetooth: true)
        io.headsetFrames(2_400, peak: 0.3, at: 0.5)
        #expect(io.observe(at: 0.6, engineRunning: false) == .reattach)
        #expect(io.obligation?.reason == .engineStopped && io.framework == 1)
    }

    @Test func ceasedIOOnARunningEngineOpensAnObligation() {
        var io = HeadsetIOGuard(bluetooth: true)
        io.headsetFrames(2_400, peak: 0.3, at: 1.0)
        #expect(io.observe(at: 1.4, engineRunning: true) == .none)
        #expect(io.observe(at: 1.5, engineRunning: true) == .reattach)
        #expect(io.obligation?.reason == .ioCeased)
    }

    @Test func aDeclinedReattachStaysOwed() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(io.configurationChanged(at: 1.0, engineRunning: false) == .reattach)
        io.reattachDeclined()                                    // the episode was still verifying
        #expect(io.reattaches == 0 && io.obligation != nil)
        #expect(io.observe(at: 1.1, engineRunning: false) == .reattach)
    }

    /// Review F3: the episode's budget is spent, so the re-attach cannot run — the obligation must
    /// not be re-offered every 100 ms tick (it stays open and visible instead).
    @Test func aReattachTheEpisodeCannotAdmitIsNotReofferedEveryTick() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(io.observe(at: 1.0, engineRunning: false) == .reattach)
        io.reattachUnavailable()
        var offered = 0
        for tick in 1...50 where io.observe(at: 1.0 + Double(tick) * 0.1, engineRunning: false) == .reattach { offered += 1 }
        #expect(offered == 0)
        #expect(io.obligation?.reason == .engineStopped && io.reattaches == 0 && io.held == 1)
    }

    @Test func reattachBudgetIsBounded() {
        var io = HeadsetIOGuard(bluetooth: true)
        var given = 0
        for step in 0..<10 {
            let t = Double(step) * 3
            if io.configurationChanged(at: t, engineRunning: false) == .reattach { given += 1 }
            io.headsetFrames(2_400, peak: 0.3, at: t + 0.1)
            _ = io.observe(at: t + 0.2, engineRunning: true)
        }
        #expect(given == HeadsetIOGuard.maxReattaches)
        #expect(io.configurationChanged(at: 40, engineRunning: false) == .exhausted)
    }

    // MARK: Sustained signal, format generations

    @Test func oneNonzeroSpikeIsNotSustainedSignal() {
        var signal = SustainedSignal()
        #expect(signal.add(frames: 2_400, peak: 0, at: 1.0) == nil)
        #expect(signal.add(frames: 2_400, peak: 0.4, at: 1.1) == nil)          // 100 ms spike
        #expect(signal.add(frames: 2_400, peak: 0, at: 1.2) == nil)            // then zeros
        #expect(signal.add(frames: 2_400, peak: 0.2, at: 1.3) == nil)
        #expect(signal.add(frames: 1_200, peak: 0.2, at: 1.35) == 1.35)        // 150 ms consecutive
        #expect(signal.add(frames: 2_400, peak: 0.2, at: 1.45) == nil)         // reported once
    }

    @Test func convertsInTapOnlyUntilSustainedSignal() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(!io.convertsInTap)
        _ = io.configurationChanged(at: 0, engineRunning: false)
        #expect(io.convertsInTap)
        io.headsetFrames(2_400, peak: 0.3, at: 0.1)
        #expect(io.convertsInTap)                                // 100 ms: not yet sustained
        io.headsetFrames(1_200, peak: 0.3, at: 0.15)
        #expect(!io.convertsInTap && io.settled)                 // v1.10: true for the guard's lifetime
        _ = io.configurationChanged(at: 1, engineRunning: true)  // a new format generation
        #expect(io.convertsInTap && io.formatGeneration == 2)
    }

    @Test func aRunningEngineIsLeftAloneUntilSettledThenTheEpisodeDecides() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(io.configurationChanged(at: 1, engineRunning: true) == .leaveRunning)
        #expect(io.allows(at: 1.01))                             // nothing in flight: no blind window
        io.headsetFrames(3_600, peak: 0.3, at: 1.2)
        #expect(io.configurationChanged(at: 3, engineRunning: true) == .episode)
    }

    @Test func otherInputsAreCountedButNeverHeld() {
        var io = HeadsetIOGuard(bluetooth: false)
        #expect(io.configurationChanged(at: 1, engineRunning: false) == .episode)
        #expect(io.allows(at: 1.01) && !io.convertsInTap && io.remaining(at: 1.01) == 0)
        #expect(io.observe(at: 1.1, engineRunning: false) == .none)
        io.record(.retap); io.record(.start)
        #expect(io.note == "io_ops=start:1 stop:0 rebuild:0 retap:1 attempted:2 completed:0 failed:0 framework:0")
    }

    // MARK: io_ops split

    struct Boom: Error {}

    @Test func ioOpsSplitAttemptedCompletedFailedFramework() {
        var io = HeadsetIOGuard(bluetooth: true)
        io.run(.start) {}
        #expect(throws: Boom.self) { try io.run(.retap) { throw Boom() } }
        io.record(.stop)                                         // the final teardown: attempted at line time
        _ = io.configurationChanged(at: 1, engineRunning: false) // the OS stopped the engine
        #expect(io.note == "io_ops=start:1 stop:1 rebuild:0 retap:1 attempted:3 completed:1 failed:1 framework:1")
        io.record(.align); io.finished(.align, ok: true)
        #expect(io.note == "io_ops=start:1 stop:1 rebuild:0 retap:1 align:1 attempted:4 completed:2 failed:1 framework:1")
    }

    @Test func boundIsTheVerificationWindow() {
        #expect(HeadsetIOGuard.inFlightBound == BluetoothRecoveryEpisode.successWithin)
        #expect(HeadsetIOGuard.handsOff == 1.0)
    }

    // MARK: R3 replay — c35bde97, 2026-10-13 07:08:26 (+08), times in s after 07:08:26.000

    /// B19:27626 IO start .108671; B19:27918 IO stop .167384 (SCO creation, AVAudioEngine stops);
    /// N:90 our notification .281510 (engine stopped); B19:28026 SCO route disabled .289249;
    /// B19:28070 re-attached IO .325754; first buffer ≈ 25.618 + 0.909 s (first_buffer_ms=909);
    /// N:92 settled silent_frames 27.284834 — the route returned only zeros.
    @Test func r3ReplayStopObligationReattach() {
        var io = HeadsetIOGuard(bluetooth: true)
        var log: [String] = []
        for tick in stride(from: 0.126, through: 0.281, by: 0.1) {       // health clock: engine still flagged running
            if io.observe(at: tick, engineRunning: true) != .none { log.append("unexpected@\(tick)") }
        }
        let reaction = io.configurationChanged(at: 0.281510, engineRunning: false)
        if io.framework == 1 { log.append("framework_stop") }
        if io.obligation?.reason == .engineStopped { log.append("obligation_open") }
        if reaction == .reattach { log.append("reattach") }
        #expect(io.observe(at: 0.326, engineRunning: true) == .pending(until: 0.281510 + 1.0))
        // IO from .325754; the recorder's first buffer arrives at ~.527, all digital zeros.
        var verification = SustainedSignal()
        var firstFrame: Double?
        for step in 0..<20 {
            let t = 0.527 + Double(step) * 0.0213
            io.headsetFrames(1_024, peak: 0, at: t)
            firstFrame = firstFrame ?? t
            _ = verification.add(frames: 1_024, peak: 0, at: t)
        }
        if io.observe(at: 0.626, engineRunning: true) == .none, io.obligation == nil { log.append("io_observed_discharged") }
        #expect(log == ["framework_stop", "obligation_open", "reattach", "io_observed_discharged"])
        #expect(BluetoothRecoveryEpisode.verdict(since: 0.281510, firstFrame: firstFrame,
                                                 firstSignal: verification.reachedAt) == .silentFrames)
        #expect(io.convertsInTap)                                // zeros never settle the format
        #expect(io.heldNote == "io_held=0 config_notifications=1 io_obligations=1/1 io_obligation=none reattaches=1")
    }
}
