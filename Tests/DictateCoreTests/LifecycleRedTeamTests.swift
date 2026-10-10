import Foundation
import Testing
@testable import DictateCore

@Suite("LifecycleRedTeam", .serialized)
struct LifecycleRedTeamTests {
    func idle(_ engine: RedTeamEngine, _ lifecycle: CaptureLifecycle) {
        #expect(!engine.isAllocated)
        #expect(!engine.isRunning)
        #expect(engine.taps == 0)
        #expect(lifecycle.warmup.phase == .off)
        #expect(!lifecycle.hasPendingPrewarmExpiry)
    }
    func next(_ engine: RedTeamEngine, _ lifecycle: CaptureLifecycle, _ clock: RedTeamClock) {
        let count = engine.attempts.count
        engine.faults = []
        #expect(lifecycle.beginRecording(at: clock.now))
        #expect(engine.attempts.count == count + 1)
        #expect(engine.attempts.last == .default)
        #expect(engine.isRunning && engine.taps == 1)
        lifecycle.end(.cancel)
        idle(engine, lifecycle)
    }

    @Test(arguments: [CaptureLifecycle.End.finished(.held), .finished(.ok), .finished(.noSTT), .finished(.error), .silence], [0.0, 20.0])
    func outcomeThenDoubleTap(_ outcome: CaptureLifecycle.End, _ delay: Double) {
        let (engine, lifecycle, clock) = redTeamRig()
        #expect(lifecycle.beginRecording(at: 0))
        lifecycle.bufferArrived(at: 0.1)
        clock.advance(53)
        lifecycle.end(outcome)
        clock.advance(delay)
        idle(engine, lifecycle)
        lifecycle.firstTap()
        #expect(lifecycle.beginRecording(at: clock.now))
        #expect(engine.isRunning && engine.taps == 1)
        lifecycle.end(.cancel)
        idle(engine, lifecycle)
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func cancellationAtStablePhases(_ phase: Int) {
        let (engine, lifecycle, clock) = redTeamRig()
        if phase == 0 { lifecycle.firstTap() }
        else {
            #expect(lifecycle.beginRecording(at: 0))
            if phase > 1 { lifecycle.bufferArrived(at: 0.1) }
            if phase == 3 { lifecycle.end(.finished(.ok)) } // transcribing
            if phase == 4 { lifecycle.end(.finished(.held)); clock.advance(20) }
        }
        lifecycle.end(.cancel)
        lifecycle.bufferArrived(at: clock.now) // late callback must not prime a later session
        idle(engine, lifecycle)
        #expect(lifecycle.beginRecording(at: clock.now))
        #expect(lifecycle.warmup.phase == .warming)
        lifecycle.end(.cancel)
    }

    @Test(arguments: [RedTeamEngine.Fault.swift, .exception, .tapException])
    func startAndTapFaults(_ fault: RedTeamEngine.Fault) {
        let (engine, lifecycle, clock) = redTeamRig()
        engine.faults = [fault, .none]
        var started = false
        #expect(redTeamBoundary { started = lifecycle.beginRecording(at: 0) } == nil)
        #expect(started)
        #expect(engine.attempts == [.default, .default])
        #expect(engine.taps == 1)
        lifecycle.end(.cancel)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test(arguments: [RedTeamEngine.Fault.swift, .exception, .missingBuiltIn])
    func exhaustedChainThenDefault(_ final: RedTeamEngine.Fault) {
        let (engine, lifecycle, clock) = redTeamRig()
        engine.faults = [.swift, .swift, final]
        var started = true
        #expect(redTeamBoundary { started = lifecycle.beginRecording(at: 0) } == nil)
        #expect(!started)
        #expect(engine.attempts == [.default, .default, .builtIn])
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test func stopExceptionStillCleansUp() {
        let (engine, lifecycle, clock) = redTeamRig()
        lifecycle.firstTap()
        engine.stopRaises = true
        #expect(redTeamBoundary { lifecycle.end(.cancel) } == nil)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test func rebuildExceptionIsAnAttemptFailure() {
        let (engine, lifecycle, clock) = redTeamRig()
        engine.faults = [.swift, .none]
        engine.rebuildRaises = true
        #expect(redTeamBoundary { _ = lifecycle.beginRecording(at: 0) } == nil)
        lifecycle.end(.cancel)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test func firstBufferDeadline() {
        let (engine, lifecycle, clock) = redTeamRig()
        engine.faults = [.none, .swift, .missingBuiltIn]
        #expect(lifecycle.beginRecording(at: 0))
        clock.advance(12) // three 3 s deadlines plus the 300 ms retry
        idle(engine, lifecycle)
        #expect(engine.attempts == [.default, .default, .builtIn])
        next(engine, lifecycle, clock)
    }

    @Test func capDuringWarming() throws {
        let (engine, lifecycle, clock) = redTeamRig()
        var caps = 0
        lifecycle.onMaxDuration = { caps += 1; lifecycle.end(.maxDuration) }
        #expect(lifecycle.beginRecording(at: 0))
        let cap = try #require(clock.jobs.first { $0.due == 300 })
        // Event loop stalled: deliver the overdue cap before the buffer watchdog.
        clock.now = 300
        cap.action()
        #expect(caps == 1)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test @MainActor func capDuringRetryWait() async {
        let (engine, lifecycle, clock) = redTeamRig()
        engine.faults = [.swift, .none]
        let ready = await lifecycle.beginRecordingAsync(at: 0,
            start: { try engine.start(device: $0) }, rebuild: { engine.rebuild() },
            wait: { _ in clock.advance(300) }, isCancelled: { false })
        #expect(!ready)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test @MainActor func capDuringCancellation() async {
        let (engine, lifecycle, clock) = redTeamRig()
        let ready = await lifecycle.beginRecordingAsync(at: 0,
            start: { device in lifecycle.end(.cancel); clock.advance(300); try engine.start(device: device) },
            rebuild: { engine.rebuild() }, wait: { clock.advance($0) }, isCancelled: { false })
        #expect(!ready)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test(arguments: [false, true]) @MainActor
    func lateStartAfterCancel(_ prewarm: Bool) async {
        let (engine, lifecycle, clock) = redTeamRig()
        let start: (MicChoice) async throws -> Void = { device in
            lifecycle.end(.cancel)
            try engine.start(device: device)
        }
        if prewarm { await lifecycle.firstTapAsync(start: start, isCancelled: { false }) }
        else {
            #expect(await !lifecycle.beginRecordingAsync(at: 0, start: start,
                rebuild: { engine.rebuild() }, wait: { clock.advance($0) }, isCancelled: { false }))
        }
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test(arguments: [0, 1, 2]) @MainActor
    func cancelAtRecoveryBoundaries(_ boundary: Int) async {
        let (engine, lifecycle, clock) = redTeamRig()
        engine.faults = boundary == 2 ? [.swift, .swift, .none] : [.swift, .none]
        var cancelled = false
        let ready = await lifecycle.beginRecordingAsync(at: 0,
            start: { device in
                if device == .builtIn { cancelled = true; lifecycle.end(.cancel) }
                try engine.start(device: device)
            }, rebuild: {
                engine.rebuild()
                if boundary == 0 { cancelled = true; lifecycle.end(.cancel) }
            }, wait: { seconds in
                clock.advance(seconds)
                if boundary == 1 { cancelled = true; lifecycle.end(.cancel) }
            }, isCancelled: { cancelled })
        #expect(!ready)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test func lateBufferAfterStop() {
        let (engine, lifecycle, clock) = redTeamRig()
        #expect(lifecycle.beginRecording(at: 0))
        lifecycle.end(.cancel)
        lifecycle.bufferArrived(at: 1)
        #expect(lifecycle.beginRecording(at: 2))
        #expect(lifecycle.warmup.phase == .warming)
        lifecycle.end(.cancel)
        next(engine, lifecycle, clock)
    }

    @Test func expiryRacingDoubleTap() {
        let (engine, lifecycle, clock) = redTeamRig()
        lifecycle.firstTap()
        let staleExpiry = clock.jobs.last!
        #expect(lifecycle.beginRecording(at: 0.3))
        staleExpiry.action() // callback already dequeued before the double tap
        #expect(engine.isRunning)
        #expect(lifecycle.warmup.phase == .warming)
        lifecycle.end(.cancel)
    }

    @Test(arguments: [false, true]) func hardwareStopsItself(_ prewarm: Bool) {
        let (engine, lifecycle, clock) = redTeamRig()
        if prewarm { lifecycle.firstTap() } else { #expect(lifecycle.beginRecording(at: 0)); lifecycle.bufferArrived(at: 0.1) }
        engine.isRunning = false // HFP -> A2DP or call end, stale phase
        engine.taps = 0
        #expect(lifecycle.beginRecording(at: 1))
        #expect(engine.attempts.count == 2)
        #expect(lifecycle.warmup.phase == .warming)
        lifecycle.end(.cancel)
        next(engine, lifecycle, clock)
    }

    @Test(arguments: [false, true]) @MainActor func rapidFinishDuringRetry(_ singleTap: Bool) async {
        let (engine, lifecycle, clock) = redTeamRig()
        var machine = DictationStateMachine()
        #expect(machine.doubleTap() == .startRecording)
        engine.faults = [.swift]
        let ready = await lifecycle.beginRecordingAsync(at: 0,
            start: { try engine.start(device: $0) }, rebuild: { engine.rebuild() }, wait: { seconds in
                clock.advance(seconds)
                #expect((singleTap ? machine.singleTap() : machine.doubleTap()) == .finishRecording)
                lifecycle.end(.cancel) // controller cancels while micStarting
            }, isCancelled: { false })
        #expect(!ready)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test func repeatedSeededCycles() {
        let (engine, lifecycle, clock) = redTeamRig()
        var seed: UInt64 = 0xD1C7A7E
        for cycle in 0..<200 {
            seed = seed &* 6364136223846793005 &+ 1
            let failures = Int((seed >> 32) % 4)
            engine.faults = Array(repeating: cycle % 2 == 0 ? .swift : .exception, count: failures)
            #expect(lifecycle.beginRecording(at: clock.now) == (failures < 3))
            #expect(engine.taps <= 1)
            lifecycle.end(cycle % 2 == 0 ? .cancel : .finished(.held))
            idle(engine, lifecycle)
            next(engine, lifecycle, clock)
        }
    }

    @Test @MainActor func reentrantCancelFromWarmingEffect() async {
        for asynchronous in [false, true] {
            let (engine, lifecycle, clock) = redTeamRig()
            var effects = 0
            lifecycle.onEffect = { effect in
                if effect == .showWarming { effects += 1; lifecycle.end(.cancel) }
            }
            let started: Bool
            if asynchronous {
                started = await lifecycle.beginRecordingAsync(at: 0,
                    start: { try engine.start(device: $0) }, rebuild: { engine.rebuild() },
                    wait: { clock.advance($0) }, isCancelled: { false })
            } else { started = lifecycle.beginRecording(at: 0) }
            #expect(!started && effects == 1)
            #expect(engine.attempts.isEmpty)
            idle(engine, lifecycle)
            lifecycle.onEffect = nil
            next(engine, lifecycle, clock)
        }
    }

    @Test func reentrantPrewarmCancel() {
        let (engine, lifecycle, clock) = redTeamRig()
        engine.onStart = { lifecycle.end(.cancel) }
        lifecycle.firstTap()
        idle(engine, lifecycle)
        engine.onStart = nil
        next(engine, lifecycle, clock)
    }

    @Test func reentrantCancelInsideSyncStart() {
        let (engine, lifecycle, clock) = redTeamRig()
        var cancellations = 0
        engine.onStart = {
            cancellations += 1
            if cancellations == 1 { lifecycle.end(.cancel) }
        }
        #expect(!lifecycle.beginRecording(at: 0))
        #expect(engine.attempts.count == 1)
        idle(engine, lifecycle)
        engine.onStart = nil
        next(engine, lifecycle, clock)
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func configurationChange(_ mode: Int) {
        let (engine, lifecycle, clock) = redTeamRig()
        if mode == 3 { lifecycle.firstTap() }
        else { #expect(lifecycle.beginRecording(at: 0)); lifecycle.bufferArrived(at: 0.1) }
        let observedEpoch = lifecycle.epoch
        if mode == 4 { lifecycle.end(.cancel); engine.rebuild() } // replaced engine's stale observer
        if mode == 1 || mode == 2 { engine.faults = [.tapException, .none] }
        engine.rebuildRaises = mode == 2
        var retaps = 0, rebuilds = 0, errors = 0, failures = 0
        lifecycle.onFailure = { failures += 1 }
        let result = CaptureConfigurationRecovery.run(isCurrent: {
            lifecycle.epoch === observedEpoch && lifecycle.warmup.phase != .off
        }, retap: {
            retaps += 1
            engine.taps = 0 // removed old tap; hardware engine stopped on config change
            engine.isRunning = false
            try engine.start(device: .default)
        }, rebuildAndStart: {
            rebuilds += 1
            try captureObjC { engine.rebuild() }
            try engine.start(device: .default)
        }, teardown: { _ = engine.stop() }, note: { _ in errors += 1 })
        if result == .failed { lifecycle.engineFailed(epoch: observedEpoch) }
        #expect(result == [CaptureConfigurationRecovery.Result.retapped, .rebuilt, .failed, .retapped, .stale][mode])
        #expect(retaps == (mode == 4 ? 0 : 1))
        #expect(rebuilds == (mode == 1 || mode == 2 ? 1 : 0))
        #expect(errors == (mode == 2 ? 2 : mode == 1 ? 1 : 0))
        #expect(failures == (mode == 2 ? 1 : 0))
        if mode == 4 { clock.advance(lifecycle.idleReleaseSeconds) } // stray idle rebuild
        if mode == 2 || mode == 4 { idle(engine, lifecycle) }
        else { #expect(engine.isRunning && engine.taps == 1); lifecycle.end(.cancel) }
        next(engine, lifecycle, clock)
    }

    @Test(arguments: [false, true]) func cancelDuringConfigurationRecovery(_ rebuild: Bool) {
        let (engine, lifecycle, clock) = redTeamRig()
        #expect(lifecycle.beginRecording(at: 0))
        let token = lifecycle.epoch
        var builds = 0
        let result = CaptureConfigurationRecovery.run(isCurrent: { lifecycle.epoch === token },
            retap: {
                if rebuild { throw NSError(domain: "retap", code: 1) }
                lifecycle.end(.cancel)
            }, rebuildAndStart: { builds += 1; lifecycle.end(.cancel) },
            teardown: { _ = engine.stop() }, note: { _ in })
        #expect(result == .stale)
        #expect(builds == (rebuild ? 1 : 0))
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test(arguments: [0, 1, 2]) func cleanupRunsAllCallsDespiteException(_ faultAt: Int) {
        var calls: [Int] = [], errors = 0
        let clean = CaptureConfigurationRecovery.teardown((0..<3).map { index in
            return {
                calls.append(index)
                if index == faultAt {
                    NSException(name: .internalInconsistencyException, reason: "cleanup", userInfo: nil).raise()
                }
            }
        }, note: { _ in errors += 1 })
        #expect(!clean && errors == 1 && calls == [0, 1, 2])
        var goodCalls = 0
        #expect(CaptureConfigurationRecovery.teardown([{ goodCalls += 1 }], note: { _ in errors += 1 }))
        #expect(goodCalls == 1 && errors == 1)
    }

    @Test func noMicIsReportedExactlyOnceAndNextUsesDefault() {
        let (engine, lifecycle, clock) = redTeamRig()
        var failures = 0
        lifecycle.onFailure = { failures += 1 }
        engine.faults = [.swift, .exception, .missingBuiltIn]
        #expect(!lifecycle.beginRecording(at: 0))
        #expect(failures == 1)
        let failedToken = lifecycle.epoch
        lifecycle.engineFailed(epoch: failedToken)
        clock.advance(300)
        #expect(failures == 1)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
        #expect(failures == 1)
    }

    @Test func firstBufferJustBeforeDeadlineAndLateDeadlineAreHarmless() throws {
        let (engine, lifecycle, clock) = redTeamRig()
        #expect(lifecycle.beginRecording(at: 0))
        let deadline = try #require(clock.jobs.first { $0.due == 3 })
        clock.advance(2.999)
        lifecycle.bufferArrived(at: clock.now)
        deadline.action() // already dequeued before cancellation
        clock.advance(20)
        #expect(engine.attempts == [.default] && lifecycle.warmup.phase == .live)
        lifecycle.end(.cancel)
        next(engine, lifecycle, clock)
    }

    @Test func syncNoBufferRetryCanBeCancelledDuringWait() throws {
        let (engine, lifecycle, clock) = redTeamRig()
        #expect(lifecycle.beginRecording(at: 0))
        clock.advance(3)
        let retry = try #require(clock.jobs.first { !$0.cancelled && $0.due == 3.3 })
        lifecycle.end(.cancel)
        retry.action()
        #expect(engine.attempts == [.default])
        // Capture/recovery deadlines are cancelled; only the idle guard remains.
        let pending = clock.jobs.filter { !$0.cancelled }
        #expect(pending.count == 1 && pending.first?.due == clock.now + lifecycle.idleReleaseSeconds)
        #expect(clock.jobs.filter { $0.due <= clock.now }.allSatisfy { $0.cancelled })
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test func capDuringLiveAndStaleCapAfterCancel() throws {
        let (engine, lifecycle, clock) = redTeamRig()
        var caps = 0
        lifecycle.onMaxDuration = { caps += 1; lifecycle.end(.maxDuration) }
        #expect(lifecycle.beginRecording(at: 0))
        lifecycle.bufferArrived(at: 0.1)
        let cap = try #require(clock.jobs.first { $0.due == 300 })
        clock.advance(300)
        #expect(caps == 1)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
        cap.action()
        #expect(caps == 1)
        idle(engine, lifecycle)
    }

    @Test func epochIdentityCannotWrapOrAcceptOldBuffer() {
        let (engine, lifecycle, clock) = redTeamRig()
        #expect(lifecycle.beginRecording(at: 0))
        let old = lifecycle.epoch
        // No integer is incremented anywhere: retained identities cannot wrap.
        for _ in 0..<2000 { lifecycle.end(.cancel); #expect(lifecycle.epoch !== old) }
        #expect(lifecycle.beginRecording(at: 1))
        lifecycle.bufferArrived(at: 1.1, epoch: old)
        lifecycle.engineFailed(epoch: old)
        #expect(engine.isRunning && lifecycle.warmup.phase == .warming)
        lifecycle.bufferArrived(at: 1.2, epoch: lifecycle.epoch)
        #expect(lifecycle.warmup.phase == .live)
        lifecycle.end(.cancel)
        next(engine, lifecycle, clock)
    }

    @Test @MainActor func asynchronousNoBufferChainExhaustsOnce() async {
        let (engine, lifecycle, clock) = redTeamRig()
        var failures = 0, waits: [Double] = []
        lifecycle.onFailure = { failures += 1 }
        #expect(await lifecycle.beginRecordingAsync(at: 0,
            start: { try engine.start(device: $0) }, rebuild: { engine.rebuild() },
            wait: { waits.append($0); clock.advance($0) }, isCancelled: { false }))
        for expectedAttempts in 2...4 {
            clock.advance(3)
            // Drain main-actor recovery tasks; no elapsed-time waits.
            for _ in 0..<100 {
                if engine.attempts.count >= expectedAttempts || failures > 0 { break }
                await Task.yield()
            }
            #expect(engine.attempts.count == min(expectedAttempts, 3))
        }
        #expect(engine.attempts == [.default, .default, .builtIn])
        #expect(waits == [0.3] && failures == 1)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test @MainActor func cancellationBeforeAsyncWatchdogRecoveryTask() async {
        let (engine, lifecycle, clock) = redTeamRig()
        #expect(await lifecycle.beginRecordingAsync(at: 0,
            start: { try engine.start(device: $0) }, rebuild: { engine.rebuild() },
            wait: { clock.advance($0) }, isCancelled: { false }))
        clock.advance(3) // schedules recovery on MainActor; cancel before task starts
        lifecycle.end(.cancel)
        for _ in 0..<10 { await Task.yield() }
        #expect(engine.attempts == [.default])
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test func staleExpiryFromFailedPrewarmCannotStopNewPrewarm() throws {
        let (engine, lifecycle, clock) = redTeamRig()
        engine.faults = [.swift]
        lifecycle.firstTap()
        let stale = try #require(clock.jobs.last)
        lifecycle.firstTap()
        #expect(engine.attempts.count == 2 && engine.isRunning)
        stale.action()
        #expect(engine.isRunning && lifecycle.warmup.phase == .prewarming)
        clock.advance(CaptureWarmup.prewarmTimeout)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test @MainActor func prewarmBufferBeforeStartContinuation() async {
        let (engine, lifecycle, clock) = redTeamRig()
        await lifecycle.firstTapAsync(start: { device in
            try engine.start(device: device)
            // Audio has arrived, but the suspended start continuation has not
            // resumed on the main event queue yet.
            lifecycle.bufferArrived(at: 0.1, epoch: lifecycle.epoch)
        }, isCancelled: { false })
        #expect(lifecycle.beginRecording(at: 0.2))
        #expect(lifecycle.warmup.phase == .live)
        clock.advance(12)
        #expect(engine.attempts == [.default])
        #expect(engine.isRunning && engine.taps == 1)
        lifecycle.end(.cancel)
        idle(engine, lifecycle)
        next(engine, lifecycle, clock)
    }

    @Test func configurationCompletionAfterCancelCannotReactivate() {
        let (engine, lifecycle, clock) = redTeamRig()
        #expect(lifecycle.beginRecording(at: 0))
        let token = lifecycle.epoch
        let result = CaptureConfigurationRecovery.run(isCurrent: { lifecycle.epoch === token },
            retap: {}, rebuildAndStart: {}, teardown: { _ = engine.stop() }, note: { _ in })
        #expect(result == .retapped)
        // stop() invalidates the recorder epoch after the policy's final check
        // but before the engine-queue completion acquires the state lock.
        lifecycle.end(.cancel)
        var activations = 0
        #expect(!CaptureConfigurationRecovery.activate(epoch: token, current: lifecycle.epoch) {
            activations += 1
            engine.isRunning = true
        })
        #expect(activations == 0)
        idle(engine, lifecycle)
        #expect(CaptureConfigurationRecovery.activate(epoch: lifecycle.epoch, current: lifecycle.epoch) {
            activations += 1
        })
        #expect(activations == 1)
        next(engine, lifecycle, clock)
    }
    // MARK: D0b — first-tap pre-start, pre-roll, lone tap, D-b release

    private func preRollRig() -> (PreRollEngine, CaptureLifecycle, RedTeamClock) {
        let clock = RedTeamClock()
        let engine = PreRollEngine(clock: clock)
        return (engine, CaptureLifecycle(engine: engine, scheduler: clock), clock)
    }
    private func frames(_ start: Int, _ count: Int) -> [Float] { (start..<(start + count)).map(Float.init) }

    @Test func firstTapStartsBuiltinAndHeadsetTogether() {
        let (engine, lifecycle, _) = preRollRig()
        lifecycle.firstTap()
        #expect(engine.builtin.isRunning && engine.builtin.attempts == [.builtIn])
        #expect(engine.headset.isRunning && engine.headset.attempts == [.default])
        #expect(lifecycle.warmup.phase == .prewarming) // never shows recording before the second tap
        lifecycle.end(.cancel)
    }

    @Test func loneTapDiscardsRingAndReleasesBothWithinOneSecond() {
        let (engine, lifecycle, clock) = preRollRig()
        lifecycle.firstTap()
        for i in 0..<10 { engine.deliver(.builtin, at: 0.05 + Double(i) * 0.05, frames: frames(i * 1200, 1200)) }
        clock.advance(0.69)
        #expect(engine.isAllocated && engine.feed.ring.count > 0) // positive control: the window is still open
        clock.advance(0.01) // the double-tap window + maxHold (0.7 s) closes
        #expect(!engine.isAllocated && !engine.builtin.isAllocated && !engine.headset.isAllocated)
        #expect(engine.feed.ring.count == 0 && engine.samples.isEmpty)
        #expect(lifecycle.warmup.phase == .off)
        next(engine.headset, lifecycle, clock)
    }

    @Test func doubleTapKeepsPreRollAndHandsOverExactly() {
        let (engine, lifecycle, clock) = preRollRig()
        lifecycle.firstTap()
        for i in 0..<5 { engine.deliver(.builtin, at: 0.10 + Double(i) * 0.05, frames: frames(i * 1200, 1200)) }
        clock.advance(0.35)
        engine.resetCapture(at: 0.35)
        #expect(lifecycle.beginRecording(at: 0.35))
        #expect(engine.samples == frames(2400, 3600)) // boundary − 150 ms, available at the tap
        #expect(engine.feed.bridge.firstKeptMs == 0)
        #expect(lifecycle.warmup.phase == .warming) // honest: the headset is not live yet
        engine.deliver(.builtin, at: 0.35, frames: frames(6000, 1200))
        engine.deliver(.headset, at: 0.38, frames: Array(repeating: -1, count: 1200), arrivedAt: 1.4)
        lifecycle.bufferArrived(at: 1.4)
        #expect(lifecycle.warmup.phase == .live && !engine.builtin.isAllocated)
        engine.deliver(.headset, at: 0.43, frames: Array(repeating: -2, count: 1200))
        // 0.20 ..< 0.48: no duplicate at the handover, no gap.
        #expect(engine.samples.count == 6720)
        let captured = lifecycle.end(.finished(.ok))
        #expect(captured.count == 6720 && Array(captured.prefix(4800)) == frames(2400, 4800))
        #expect(!engine.isAllocated)
    }

    @Test func builtinDefaultMicPreStartsOnFirstTapAndKeepsPreRoll() {
        let (engine, lifecycle, clock) = preRollRig()
        engine.defaultInput = .builtin
        lifecycle.firstTap()
        #expect(engine.headset.isRunning && !engine.builtin.isAllocated) // one engine: the default IS built-in
        for i in 0..<4 { engine.deliver(.headset, at: 0.12 + Double(i) * 0.05, frames: frames(i * 1200, 1200)) }
        lifecycle.bufferArrived(at: 0.13)
        clock.advance(0.3)
        engine.resetCapture(at: 0.30)
        #expect(lifecycle.beginRecording(at: 0.30))
        #expect(engine.samples == frames(720, 4080) && engine.feed.bridge.firstKeptMs == 0)
        #expect(lifecycle.warmup.phase == .live && lifecycle.warmup.warmMs == 0)
        lifecycle.end(.cancel)
        #expect(!engine.isAllocated)
    }

    /// D-b (live 12:00:20Z…): after a bridged dictation the bridge executor never
    /// ran its teardown, so `isAllocated` stayed true and the guard logged every 2 s.
    @Test(arguments: [false, true])
    func wedgedBridgeIsAbandonedSoBothEnginesReleaseWithinTwoSeconds(_ wedgeAtStart: Bool) {
        let (engine, lifecycle, clock) = preRollRig()
        var notes: [String] = []
        lifecycle.note = { notes.append($0) }
        engine.builtinWedged = wedgeAtStart
        lifecycle.firstTap()
        engine.builtinWedged = true // otherwise its handover teardown is the call that never returns
        clock.advance(0.3)
        engine.resetCapture(at: 0.3)
        #expect(lifecycle.beginRecording(at: 0.3))
        engine.deliver(.headset, at: 1.0, frames: frames(0, 1200), arrivedAt: 1.1)
        lifecycle.bufferArrived(at: 1.1)
        clock.advance(20)
        #expect(engine.builtin.isAllocated && engine.abandoned == 0) // positive control: v1.5.4 stays here
        lifecycle.end(.finished(.ok))
        #expect(engine.abandoned == 1 && !engine.isAllocated) // at the finish, well inside 2 s
        clock.advance(30)
        #expect(!engine.isAllocated && !notes.contains("engine_idle_release"))
        next(engine.headset, lifecycle, clock) // the next dictation gets a fresh bridge executor
        #expect(engine.abandoned == 1)
    }

    @Test func wedgedBridgeAfterALoneTapIsReleasedByTheIdleGuardOnce() {
        let (engine, lifecycle, clock) = preRollRig()
        var notes: [String] = []
        lifecycle.note = { notes.append($0) }
        engine.builtinWedged = true
        lifecycle.firstTap()
        clock.advance(0.7) // lone tap: expiry releases; the wedge is only 0.7 s old
        #expect(engine.isAllocated && engine.abandoned == 0)
        clock.advance(2.0) // idle guard: ≤ 2 s after the release
        #expect(!engine.isAllocated && engine.abandoned == 1)
        clock.advance(30)
        #expect(notes == ["engine_idle_release"])
        next(engine.headset, lifecycle, clock)
    }

    @Test func executorWatchFlagsOnlyAnOperationThatNeverReturns() {
        var watch = CaptureExecutorWatch()
        #expect(!watch.isWedged(at: 100))
        watch.began(at: 10)
        #expect(!watch.isWedged(at: 10 + CaptureExecutorWatch.wedgeSeconds - 0.01))
        #expect(watch.isWedged(at: 10 + CaptureExecutorWatch.wedgeSeconds))
        watch.ended()
        #expect(!watch.isWedged(at: 100) && watch.busySince == nil)
    }
}
