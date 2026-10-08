import Foundation
import Testing
import DictateObjC
@testable import DictateCore

private final class FakeAudioEngine: CaptureEngine {
    enum Action { case succeed, swiftError, raise }
    var actions: [Action] = []
    var raisesUntilRebuild = false
    var isRunning = false
    var tapInstalled = false
    var observerInstalled = false
    var converterInstalled = false
    var attempts: [MicChoice] = []
    var rebuilds = 0
    func start(device: MicChoice) throws {
        attempts.append(device)
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
    func rebuild() { _ = stop(); rebuilds += 1; raisesUntilRebuild = false }
}

/// Catch at the event-loop boundary, outside the Swift lifecycle call.
private func appKitEvent(_ operation: () -> Void) -> NSError? {
    var error: NSError?
    _ = DictateTryObjC(operation, &error)
    return error
}

@Suite("CaptureLifecycle")
struct CaptureLifecycleTests {
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
        lifecycle.end(path)
        #expect(!engine.isRunning)
        #expect(!engine.tapInstalled)
        #expect(!engine.observerInstalled && !engine.converterInstalled)
        #expect(lifecycle.warmup.phase == .off)
        #expect(!lifecycle.hasPendingPrewarmExpiry)
        #expect(!hooksInstalled)
        #expect(lifecycle.beginRecording(at: 2))
    }
}
