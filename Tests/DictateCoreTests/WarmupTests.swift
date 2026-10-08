import Testing
import DictateCore

/// The pre-warm / WARMING state machine, driven like a fake engine would drive it.
@Suite("CaptureWarmup")
struct WarmupTests {
    @Test func firstTapPrewarmsAndBuffersBeforeSecondTapGoLiveAtOnce() {
        var w = CaptureWarmup()
        #expect(w.firstTap() == [.startEngine])
        #expect(w.bufferArrived(at: 0.10) == [])            // engine flowing while still pre-warming
        #expect(w.recordingStarted(at: 0.30) == [.showLive])
        #expect(w.phase == .live)
        #expect(w.warmMs == 0)
    }

    @Test func bluetoothSwitchShowsWarmingUntilFirstBuffer() {
        var w = CaptureWarmup()
        _ = w.firstTap()
        #expect(w.recordingStarted(at: 1.00) == [.showWarming])
        #expect(w.phase == .warming)
        #expect(w.bufferArrived(at: 2.25) == [.showLive])
        #expect(w.warmMs == 1250)
        #expect(w.bufferArrived(at: 2.30) == [])             // only the first buffer flips the pill
    }

    @Test func prewarmWithoutDoubleTapStopsSilently() {
        var w = CaptureWarmup()
        _ = w.firstTap()
        #expect(w.prewarmExpired() == [.stopEngine])
        #expect(w.phase == .off)
        #expect(w.firstTap() == [.startEngine])              // next tap pre-warms again
    }

    @Test func expiryAfterRecordingStartedIsIgnored() {
        var w = CaptureWarmup()
        _ = w.firstTap()
        _ = w.recordingStarted(at: 0.3)
        #expect(w.prewarmExpired() == [])
        #expect(w.phase == .warming)
    }

    @Test func menuStartWithoutPrewarmStartsEngineAndWarms() {
        var w = CaptureWarmup()
        #expect(w.recordingStarted(at: 5.0) == [.startEngine, .showWarming])
        #expect(w.bufferArrived(at: 5.4) == [.showLive])
        #expect(w.warmMs == 400)
    }

    @Test func stoppedResets() {
        var w = CaptureWarmup()
        _ = w.firstTap()
        _ = w.bufferArrived(at: 0.1)
        w.stopped()
        #expect(w.phase == .off)
        #expect(w.recordingStarted(at: 1.0) == [.startEngine, .showWarming])
    }

    @Test func prewarmTimeoutCoversTheDoubleTapWindow() {
        #expect(CaptureWarmup.prewarmTimeout == 0.7)
    }
}
