import Foundation
import Testing
import DictateObjC
@testable import DictateCore

private final class FakeAudioEngine: CaptureEngine {
    enum Action { case succeed, swiftError, raise }
    var actions: [Action] = []
    var raisesUntilRebuild = false
    // Allocation identities make retention visible independently of running/tap state.
    final class Allocation {}
    private(set) var allocation: Allocation? = Allocation()
    private(set) var allocations = 1
    private(set) var releases = 0
    var isAllocated: Bool { allocation != nil }
    var isRunning = false
    var tapInstalled = false
    var observerInstalled = false
    var converterInstalled = false
    var attempts: [MicChoice] = []
    var rebuilds = 0
    var events: [String] = []
    /// D-b: an engine whose release cannot complete (wedged executor) stays allocated.
    var releaseSticks = false
    func start(device: MicChoice) throws {
        if allocation == nil { allocation = Allocation(); allocations += 1 }
        attempts.append(device)
        events.append(device == .default ? "default" : "builtin")
        tapInstalled = true
        let action = raisesUntilRebuild ? Action.raise : (actions.isEmpty ? .succeed : actions.removeFirst())
        switch action {
        case .succeed: isRunning = true; observerInstalled = true; converterInstalled = true
        case .swiftError: throw NSError(domain: "FakeAudio", code: 7)
        case .raise:
            NSException(name: .internalInconsistencyException, reason: "stale input format / tap already installed", userInfo: nil).raise()
        }
    }
    func stop() -> [Float] {
        isRunning = false; tapInstalled = false; observerInstalled = false; converterInstalled = false
        return []
    }
    func release() { _ = stop(); if !releaseSticks { allocation = nil }; releases += 1 }
    func rebuild() {
        events.append("rebuild")
        release()
        allocation = Allocation(); allocations += 1
        rebuilds += 1; raisesUntilRebuild = false
    }
}

/// Catch at the event-loop boundary, outside the Swift lifecycle call.
private func appKitEvent(_ operation: () -> Void) -> NSError? {
    var error: NSError?
    _ = DictateTryObjC(operation, &error)
    return error
}

@Suite("CaptureLifecycle")
struct CaptureLifecycleTests {
    @Test(arguments: [CaptureLifecycle.End.finished(.ok), .finished(.held), .finished(.noSTT), .finished(.error), .silence, .cancel, .fail, .prewarmExpired, .maxDuration])
    func everyEndPathReleasesEngine(path: CaptureLifecycle.End) {
        let engine = FakeAudioEngine(), clock = RedTeamClock()
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: clock)
        lifecycle.firstTap()
        if case .prewarmExpired = path {} else { #expect(lifecycle.beginRecording(at: 0)) }
        #expect(engine.isAllocated) // positive control: every path starts with an allocation
        lifecycle.end(path)
        #expect(engine.isAllocated == false)
        #expect(engine.releases > 0)
    }

    @Test func idleGuardReleasesLeftoverEngine() {
        let engine = FakeAudioEngine(), clock = RedTeamClock()
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: clock)
        var notes: [String] = []
        lifecycle.note = { notes.append($0) }
        #expect(engine.isAllocated && lifecycle.warmup.phase == .off)
        clock.advance(1.99)
        #expect(engine.isAllocated && engine.releases == 0 && notes.isEmpty)
        clock.advance(0.01)
        #expect(engine.isAllocated == false)
        #expect(engine.releases == 1)
        #expect(notes == ["engine_idle_release"])
        // A later stray rebuild while still idle is guarded too (released, logged once per episode).
        engine.rebuild()
        clock.advance(2)
        #expect(engine.isAllocated == false && engine.releases == 3)
        #expect(notes == ["engine_idle_release"])
    }

    /// D-b (live 12:02:11Z…12:02:40Z): an allocation that survives release must not
    /// log every 2 s; the guard keeps releasing but notes once per idle episode.
    @Test func idleGuardLogsOncePerIdleEpisode() {
        let engine = FakeAudioEngine(), clock = RedTeamClock()
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: clock)
        var notes: [String] = []
        lifecycle.note = { notes.append($0) }
        engine.releaseSticks = true
        clock.advance(30)
        #expect(engine.isAllocated && engine.releases >= 10) // positive control: still wedged, still retried
        #expect(notes == ["engine_idle_release"])
        // A new episode (after a lone tap) may log once more.
        engine.releaseSticks = false
        lifecycle.firstTap()
        engine.releaseSticks = true
        clock.advance(CaptureWarmup.prewarmTimeout)
        clock.advance(30)
        #expect(notes == ["engine_idle_release", "engine_idle_release"])
    }

    @Test func prewarmExpiryReleases() {
        let engine = FakeAudioEngine(), clock = RedTeamClock()
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: clock)
        lifecycle.firstTap()
        clock.advance(0.69)
        #expect(engine.isAllocated && lifecycle.hasPendingPrewarmExpiry)
        clock.advance(0.01)
        #expect(engine.isAllocated == false)
        #expect(lifecycle.warmup.phase == .off && !lifecycle.hasPendingPrewarmExpiry)
    }

    @Test func nextStartAllocatesFresh() {
        let engine = FakeAudioEngine()
        let capture = CaptureLifecycle(engine: engine, scheduler: RedTeamClock())
        #expect(capture.beginRecording(at: 0))
        weak let old = engine.allocation
        capture.end(.finished(.ok))
        #expect(engine.isAllocated == false)
        #expect(old == nil)
        #expect(capture.beginRecording(at: 1))
        #expect(engine.isAllocated && engine.allocations == 2)
        #expect(engine.attempts == [.default, .default])
        capture.end(.cancel)
    }

    @Test func rebuildReleasesOldEngine() {
        let engine = FakeAudioEngine()
        engine.actions = [.swiftError, .succeed]
        weak let old = engine.allocation
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: RedTeamClock())
        #expect(lifecycle.beginRecording(at: 0))
        #expect(old == nil)
        #expect(engine.isAllocated && engine.allocations == 2 && engine.releases == 1)
        #expect(engine.rebuilds == 1 && engine.attempts == [.default, .default])
        lifecycle.end(.cancel)
        #expect(engine.isAllocated == false)
    }

    @Test func idleGuardPreservesRecordingAndPrewarm() throws {
        let engine = FakeAudioEngine(), clock = RedTeamClock()
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: clock)
        let staleIdle = try #require(clock.jobs.first)
        lifecycle.firstTap()
        staleIdle.action() // cancelled, already delivered callback
        clock.advance(0.69)
        #expect(engine.isAllocated && engine.releases == 0)
        #expect(lifecycle.beginRecording(at: clock.now))
        lifecycle.bufferArrived(at: clock.now)
        staleIdle.action()
        clock.advance(2)
        #expect(engine.isAllocated && engine.isRunning && engine.releases == 0)
        lifecycle.end(.cancel)
        clock.advance(2)
        #expect(!engine.isAllocated && engine.releases == 1)
    }

    @Test func idleGuardUsesConfiguredDeadline() {
        let engine = FakeAudioEngine(), clock = RedTeamClock()
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: clock, idleReleaseSeconds: 0.5)
        #expect(lifecycle.idleReleaseSeconds == 0.5)
        clock.advance(0.49)
        #expect(engine.isAllocated && engine.releases == 0)
        clock.advance(0.01)
        #expect(!engine.isAllocated && engine.releases == 1)
    }

    @Test func heldEndThenNextStartRecords() {
        let engine = FakeAudioEngine(), lifecycle: CaptureLifecycle
        lifecycle = CaptureLifecycle(engine: engine)
        #expect(lifecycle.beginRecording(at: 0))
        lifecycle.end(.finished(.held)) // held:focus_changed follows the shared finish teardown
        lifecycle.firstTap()
        #expect(lifecycle.beginRecording(at: 1))
        #expect(engine.isRunning)
        #expect(lifecycle.warmup.phase == .warming || lifecycle.warmup.phase == .live)
    }

    @Test func prewarmRaiseDoesNotWedge() {
        let engine = FakeAudioEngine()
        engine.actions = [.raise, .succeed]
        let lifecycle = CaptureLifecycle(engine: engine)
        _ = appKitEvent { lifecycle.firstTap() }
        var started = false
        _ = appKitEvent { started = lifecycle.beginRecording(at: 1) }
        #expect(started, "second tap must retry the stopped engine despite a prewarm exception")
        #expect(engine.isRunning)
    }

    @Test func threePrewarmRaisesRecoverWithRebuild() {
        let engine = FakeAudioEngine()
        engine.raisesUntilRebuild = true
        let lifecycle = CaptureLifecycle(engine: engine)
        for attempt in 0..<3 {
            _ = appKitEvent { lifecycle.firstTap() }
            var started = false
            _ = appKitEvent { started = lifecycle.beginRecording(at: Double(attempt)) }
            #expect(started, "every attempt must recover without a process restart")
            if !started { lifecycle.end(.fail) }
        }
        #expect(engine.rebuilds > 0, "stale engine must be replaced")
        #expect(engine.isRunning, "recovery must record without a process restart")
    }

    @Test(arguments: [CaptureLifecycle.End.finished(.ok), .finished(.held), .finished(.noSTT), .finished(.error), .silence, .cancel, .fail, .prewarmExpired, .maxDuration])
    func everyEndPathTearsDown(path: CaptureLifecycle.End) {
        let engine = FakeAudioEngine()
        let lifecycle = CaptureLifecycle(engine: engine)
        var hooksInstalled = true
        lifecycle.dropHooks = { hooksInstalled = false }
        lifecycle.firstTap()
        if case .prewarmExpired = path {} else { #expect(lifecycle.beginRecording(at: 0)) }
        lifecycle.end(path)
        #expect(!engine.isRunning)
        #expect(!engine.tapInstalled)
        #expect(!engine.observerInstalled && !engine.converterInstalled)
        #expect(lifecycle.warmup.phase == .off)
        #expect(!lifecycle.hasPendingPrewarmExpiry)
        #expect(!hooksInstalled)
        #expect(lifecycle.beginRecording(at: 2))
    }

    @Test func objcBridgeHasRedAndGreenControls() throws {
        #expect(appKitEvent {} == nil)
        let error = appKitEvent {
            NSException(name: .invalidArgumentException, reason: "known-bad format", userInfo: nil).raise()
        }
        #expect(error?.domain == "DictateObjC")
        #expect(error?.userInfo["name"] as? String == "NSInvalidArgumentException")
        #expect(error?.userInfo["reason"] as? String == "known-bad format")
        #expect(try captureObjC { 42 } == 42)
        var caught: NSError?
        do { try captureObjC { NSException(name: .invalidArgumentException, reason: "known-bad format", userInfo: nil).raise() } }
        catch { caught = error as NSError }
        #expect(caught?.domain == "DictateObjC")
    }

    @Test func stoppedEngineOverridesWarmupPhase() {
        let engine = FakeAudioEngine()
        let lifecycle = CaptureLifecycle(engine: engine)
        lifecycle.firstTap()
        #expect(lifecycle.warmup.phase == .prewarming)
        _ = engine.stop() // hardware/config change stopped the engine outside warmup
        #expect(lifecycle.beginRecording(at: 1), "real engine state must override stale prewarming phase")
        #expect(engine.attempts == [.default, .default])
    }

    @Test func failedPrewarmRollsBackAndAlwaysArmsExpiry() {
        let engine = FakeAudioEngine()
        engine.actions = [.raise]
        let lifecycle = CaptureLifecycle(engine: engine)
        var scheduled = 0, cancelled = 0
        lifecycle.scheduleExpiry = { scheduled += 1 }
        lifecycle.cancelExpiry = { cancelled += 1 }
        #expect(appKitEvent { lifecycle.firstTap() } == nil) // exception converted inside lifecycle now
        #expect(lifecycle.warmup.phase == .off)
        #expect(!engine.tapInstalled)
        #expect(lifecycle.hasPendingPrewarmExpiry && scheduled == 1)
        lifecycle.end(.prewarmExpired)
        #expect(!lifecycle.hasPendingPrewarmExpiry && cancelled > 0)
    }

    @Test(arguments: [0, 1, 2, 3]) func micStartChain(successAt: Int) {
        let engine = FakeAudioEngine()
        engine.actions = Array(repeating: .swiftError, count: successAt) + [.succeed]
        let lifecycle = CaptureLifecycle(engine: engine)
        var fields: [String] = []
        lifecycle.note = { fields.append($0) }
        let started = lifecycle.beginRecording(at: 1)
        #expect(started == (successAt < 3))
        let expectedEvents = ["default", "rebuild", "default", "rebuild", "builtin"]
        let count = min(successAt * 2 + 1, 5)
        #expect(engine.events == Array(expectedEvents.prefix(count)))
        #expect(engine.attempts == Array([MicChoice.default, .default, .builtIn].prefix(min(successAt + 1, 3))))
        #expect(engine.rebuilds == min(successAt, 2))
        #expect(fields.contains("mic_retry=ok") == (successAt == 1))
        #expect(fields.contains("mic_retry=fail") == (successAt >= 2))
        #expect(fields.contains("mic_fallback=builtin") == (successAt == 2))
        #expect(lifecycle.usedBuiltIn == (successAt == 2))
        if successAt > 0 {
            #expect(fields.contains { $0.hasPrefix("mic_error=FakeAudio:7 ") })
            #expect(fields.contains { $0.hasPrefix("warm_phase=") && $0.contains("engine_running=false") })
        }
        if successAt == 3 {
            #expect(!engine.isRunning && !engine.tapInstalled)
            #expect(lifecycle.warmup.phase == .off)
        }
        lifecycle.end(.finished(.ok))
        engine.actions = [.succeed]
        #expect(lifecycle.beginRecording(at: 2))
        #expect(engine.attempts.last == .default) // built-in is for one dictation only
        #expect(!lifecycle.usedBuiltIn)
    }

    @Test @MainActor func asyncMicStartChainWaitsAndCancelsCleanly() async {
        let engine = FakeAudioEngine()
        engine.actions = [.swiftError, .succeed]
        let lifecycle = CaptureLifecycle(engine: engine)
        var waits: [TimeInterval] = []
        var cancelled = false
        let started = await lifecycle.beginRecordingAsync(at: 0,
            start: { device in try captureObjC { try engine.start(device: device) } },
            rebuild: { engine.rebuild() },
            wait: { waits.append($0); cancelled = true; lifecycle.end(.cancel) },
            isCancelled: { cancelled })
        #expect(!started)
        #expect(waits == [0.3])
        #expect(engine.attempts == [.default])
        #expect(!engine.isRunning && !engine.tapInstalled)
        #expect(lifecycle.warmup.phase == .off && !lifecycle.hasPendingPrewarmExpiry)
        #expect(lifecycle.beginRecording(at: 1))
    }

    @Test(arguments: [0, 1, 2, 3]) @MainActor func asyncMicStartChain(successAt: Int) async {
        let engine = FakeAudioEngine()
        engine.actions = Array(repeating: .raise, count: successAt) + [.succeed]
        let lifecycle = CaptureLifecycle(engine: engine)
        var fields: [String] = [], waits: [TimeInterval] = []
        lifecycle.note = { fields.append($0) }
        let started = await lifecycle.beginRecordingAsync(at: 0,
            start: { device in try captureObjC { try engine.start(device: device) } },
            rebuild: { engine.rebuild() }, wait: { waits.append($0) }, isCancelled: { false })
        #expect(started == (successAt < 3))
        #expect(engine.attempts == Array([MicChoice.default, .default, .builtIn].prefix(min(successAt + 1, 3))))
        #expect(waits == (successAt == 0 ? [] : [0.3]))
        #expect(fields.contains("mic_retry=ok") == (successAt == 1))
        #expect(fields.contains("mic_fallback=builtin") == (successAt == 2))
        if successAt > 0 {
            #expect(fields.contains { $0.hasPrefix("mic_error=DictateObjC:1 NSInternalInconsistencyException:") })
        }
    }

    @Test @MainActor func asyncPrewarmCancellationDoesNotRearmExpiry() async {
        let engine = FakeAudioEngine()
        let lifecycle = CaptureLifecycle(engine: engine)
        var cancelled = false
        await lifecycle.firstTapAsync(start: { device in
            try engine.start(device: device)
            cancelled = true
            lifecycle.end(.cancel)
        }, isCancelled: { cancelled })
        #expect(lifecycle.warmup.phase == .off)
        #expect(!lifecycle.hasPendingPrewarmExpiry && !engine.isRunning && !engine.tapInstalled)
    }


    @Test @MainActor func cancelledBeforeAsyncBeginDoesNotShowWarming() async {
        let engine = FakeAudioEngine()
        let lifecycle = CaptureLifecycle(engine: engine)
        var effects: [CaptureWarmup.Effect] = []
        lifecycle.onEffect = { effects.append($0) }
        let started = await lifecycle.beginRecordingAsync(at: 0,
            start: { device in try engine.start(device: device) },
            rebuild: { engine.rebuild() }, wait: { _ in }, isCancelled: { true })
        #expect(!started && effects.isEmpty && engine.attempts.isEmpty)
        #expect(lifecycle.warmup.phase == .off && !lifecycle.hasPendingPrewarmExpiry)
    }


    @Test @MainActor func asyncStoppedEngineOverridesWarmupPhase() async {
        let engine = FakeAudioEngine()
        let lifecycle = CaptureLifecycle(engine: engine)
        lifecycle.firstTap()
        _ = engine.stop()
        let started = await lifecycle.beginRecordingAsync(at: 1,
            start: { device in try engine.start(device: device) },
            rebuild: { engine.rebuild() }, wait: { _ in }, isCancelled: { false })
        #expect(started && engine.isRunning)
        #expect(engine.attempts == [.default, .default])
    }

}
