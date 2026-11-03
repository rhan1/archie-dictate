import Testing
@testable import DictateCore

/// v1.28 FR1-A (Astra BLOCKER 1): the recorder's escalation/verification orchestration on the PRODUCTION
/// `HeadsetIOGuard` + `BluetoothRecoveryEpisode`, on an injected clock. Mirrors `AudioRecorder`: the health tick
/// (`healthTick` → `ioGuard.observe`) reserves a re-attach; the engine executor admits it later
/// (`obligationReattach` → `episode.admitReattach`) and arms the verification (`verifyFrames`, settled on the
/// health queue `successWithin` later); an escalation goes through `requestHeadsetRestart` → `episode.request`;
/// `restartHeadset` begins the restart, arms its verification at the fresh start's entry and calls
/// `ioGuard.restarted` once the start returned. Physical model = f243a0c8: the transient link is gone (zeros) until
/// the restart re-requests HFP; the fresh engine delivers nothing and stops 250 ms after its start; a re-attach
/// after that hears the speaker.
struct EscalationRig {
    enum Order: String { case observationFirst = "observation_first", verdictFirst = "verdict_first" }
    enum Kind { case tick, admit, settle(Int), restartDue, restartEntry, restartReturn, freshStop, ioBack, notify(Bool) }
    struct Verification { let token: Int; let since: Double; var isRestart = false; var firstFrame: Double?; var signal = SustainedSignal(); var firstSignal: Double? }

    let order: Order
    /// Executor latency between the guard's reservation and the episode's admission + verification arm.
    var admitDelay: Double { order == .observationFirst ? 0.020 : 0 }
    var io = HeadsetIOGuard(bluetooth: true, transientRoute: true)
    var episode = BluetoothRecoveryEpisode(bluetooth: true)
    var events: [(at: Double, seq: Int, kind: Kind)] = []
    var seq = 0
    var engineRunning = true
    var ioFrom: Double?
    var linkUp = false
    var restarting = false
    var verification: Verification?
    var tokens = 0
    var restarts = 0
    var reattachesAdmitted = 0
    var freshStopAnswered = false
    var log: [String] = []

    init(order: Order) {
        self.order = order
        engineRunning = false                                  // the transient engine stopped at +0.95 (silently)
        var k = 0
        while true {
            let t = 1.0 + Double(k) * 0.1005                   // the 100 ms health timer, running 0.5 ms late per tick
            if t > 12 { break }
            schedule(t, .tick); k += 1
        }
        schedule(1.05, .notify(true))                          // the link's flip reaches the running engine
    }

    mutating func schedule(_ at: Double, _ kind: Kind) { seq += 1; events.append((at, seq, kind)) }
    func ms(_ t: Double) -> Int { Int((t * 1000).rounded()) }

    mutating func run() {
        while let next = events.indices.min(by: { (events[$0].at, events[$0].seq) < (events[$1].at, events[$1].seq) }) {
            let (t, _, kind) = events.remove(at: next)
            switch kind {
            case .tick: tick(t)
            case .admit: admit(t)
            case .settle(let token): settle(t, token: token)
            case .restartDue: restartDue(t)
            case .restartEntry:
                tokens += 1
                verification = Verification(token: tokens, since: t, isRestart: true)   // armed before the start (verifyFrames)
                schedule(t + BluetoothRecoveryEpisode.successWithin, .settle(tokens))
            case .restartReturn:
                restarting = false
                engineRunning = true; ioFrom = nil; linkUp = true            // HFP re-requested; no frames from it
                io.restarted(at: t)
                restarts += 1
                log.append("\(ms(t)):restart_started")
                schedule(t + 0.25, .freshStop)
            case .freshStop:
                engineRunning = false; ioFrom = nil
                episode.formatChanged(at: t)
                react(io.configurationChanged(at: t, engineRunning: false), at: t, source: "fresh_stop")
            case .ioBack:
                engineRunning = true; ioFrom = t
            case .notify(let running):
                episode.formatChanged(at: t)
                react(io.configurationChanged(at: t, engineRunning: running), at: t, source: "notify")
            }
        }
    }

    mutating func tick(_ t: Double) {
        if engineRunning, let from = ioFrom, t >= from {
            let peak: Float = linkUp ? 0.3 : 0
            io.headsetFrames(2_400, peak: peak, at: t)
            if var check = verification, t > check.since {
                if check.firstFrame == nil { check.firstFrame = t }
                if check.firstSignal == nil, let reached = check.signal.add(frames: 2_400, peak: peak, at: t) { check.firstSignal = reached }
                verification = check
            }
        }
        guard !restarting else { return }                     // healthTick skips while restarting
        react(io.observe(at: t, engineRunning: engineRunning), at: t, source: "tick")
    }

    mutating func react(_ reaction: HeadsetIOGuard.Reaction, at t: Double, source: String) {
        switch reaction {
        case .reattach: schedule(t + admitDelay, .admit)
        case .escalate:
            log.append("\(ms(t)):escalate(\(source))")
            requestRestart(t, escalation: true)
        default: break
        }
    }

    mutating func admit(_ t: Double) {
        guard episode.admitReattach(at: t) else {
            if episode.budgetSpent { io.reattachUnavailable(); log.append("\(ms(t)):reattach_unavailable") } else { io.reattachDeclined() }
            return
        }
        reattachesAdmitted += 1
        if restarts > 0 { freshStopAnswered = true }
        log.append("\(ms(t)):reattach")
        tokens += 1
        verification = Verification(token: tokens, since: t)
        schedule(t + BluetoothRecoveryEpisode.successWithin, .settle(tokens))
        io.reattachFinished(started: true, at: t)
        schedule(t + 0.09, .ioBack)
    }

    mutating func settle(_ t: Double, token: Int) {
        guard let check = verification, check.token == token else { return }
        verification = nil
        guard episode.isRunning else { return }
        let outcome = BluetoothRecoveryEpisode.verdict(since: check.since, firstFrame: check.firstFrame, firstSignal: check.firstSignal)
        episode.settled(outcome)
        io.attemptSettled()                                    // FR1-A: AudioRecorder.settledLocked
        log.append("\(ms(t)):settled=\(outcome.rawValue)")
    }

    /// `requestHeadsetRestart(…, escalation:)`: FR1-A hands the episode's answer back to the guard.
    mutating func requestRestart(_ t: Double, escalation: Bool) {
        switch episode.request(.restart, at: t) {
        case .now:
            if escalation { io.restartRequested(.queued) }
            schedule(t, .restartDue)
        case .after(let wait):
            if escalation { io.restartRequested(.queued) }
            schedule(t + wait, .restartDue); log.append("\(ms(t)):queued")
        case .coalesced:
            if escalation {
                if episode.pendingDue != nil { io.restartRequested(.queued) }
                else if restarting || verification?.isRestart == true { io.restartRequested(.started) }
                else { io.restartRequested(.coalesced) }
            }
            log.append("\(ms(t)):coalesced")
        case .exhausted:
            if escalation { io.restartRequested(.refused) }
            log.append("\(ms(t)):exhausted")
        }
    }

    mutating func restartDue(_ t: Double) {
        let held = io.remaining(at: t)
        if held > 0 { io.deferred(); schedule(t + held, .restartDue); return }
        switch episode.beginIfStable(at: t) {
        case .begun: break
        case .notPending: return
        case .wait(let more): schedule(t + more, .restartDue); return
        }
        restarting = true
        engineRunning = false; ioFrom = nil
        log.append("\(ms(t)):restart_begun")
        schedule(t + BluetoothRecoveryEpisode.settleAfterStop, .restartEntry)   // teardown + idle wait
        schedule(t + 0.9, .restartReturn)                                         // f243a0c8: ≈ 0.9 s to `started=1`
    }

    var literal: String {
        "order=\(order.rawValue) restarts=\(restarts) reattaches_admitted=\(reattachesAdmitted) attempts=\(episode.attempts)"
            + " fresh_stop_answered=\(freshStopAnswered ? 1 : 0) \(io.heldNote) :: \(log.joined(separator: " | "))"
    }
}

@Suite("V128EscalationOrdering")
struct V128EscalationOrderingTests {
    /// RED on 4b330d6 (observation first): the escalation coalesces into the running re-attach verification and is
    /// dropped; the 4.0 s fallback spends a retap; the restart then takes the third attempt and the fresh engine's
    /// stop is refused. GREEN: the restart runs once the verification settles and the fresh engine's stop still gets
    /// its re-attach within the three attempts.
    @Test(arguments: [EscalationRig.Order.observationFirst, .verdictFirst])
    func restartAndItsFollowingReattachFitTheBudget(order: EscalationRig.Order) {
        var rig = EscalationRig(order: order)
        rig.run()
        print("FR1-A LITERAL \(rig.literal)")
        #expect(rig.restarts == 1)
        #expect(rig.freshStopAnswered)
        #expect(rig.episode.attempts <= BluetoothRecoveryEpisode.maxAttempts)
        #expect(rig.io.obligation == nil)
    }
}
