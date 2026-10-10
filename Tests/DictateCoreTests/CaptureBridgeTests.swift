import Foundation
import Testing
@testable import DictateCore

@Suite("CaptureBridge")
struct CaptureBridgeTests {
    private func bridge(_ input: CaptureBridge.DefaultInput = .bluetooth,
                        builtin: Bool = true) -> CaptureBridge {
        var bridge = CaptureBridge()
        bridge.start(defaultInput: input, hasBuiltin: builtin)
        bridge.recordingStarted(at: 10)
        return bridge
    }

    @Test func bridgeFeedsBuiltinUntilHeadsetFirstBuffer() {
        var b = bridge()
        #expect(b.state == .builtinOnly)
        let first = b.buffer(source: .builtin, at: 10, frames: 2400)
        #expect(first.framesToFeed == 2400 && !first.releaseBuiltin)
        let headset = b.buffer(source: .headset, at: 10.1, frames: 2400)
        #expect(headset.framesToFeed == 2400 && headset.releaseBuiltin)
        #expect(b.state == .switched && b.bridgeMs == 100 && b.bridgeSource == "builtin")
    }

    @Test func switchAtBufferBoundaryNoGapNoDuplicateBeyond100ms() {
        var b = bridge()
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400).framesToFeed == 2400)
        let overlap = b.buffer(source: .headset, at: 10.05, frames: 2400)
        #expect(overlap.dropFrames == 1200 && overlap.framesToFeed == 1200)
        #expect(overlap.releaseBuiltin)
        #expect(b.buffer(source: .headset, at: 10.15, frames: 2400).framesToFeed == 2400)
    }

    @Test func builtinReleasedAfterSwitch() throws {
        let builtin = RedTeamEngine()
        try builtin.start(device: .builtIn)
        var b = bridge()
        #expect(builtin.isAllocated && builtin.isRunning)
        let decision = b.buffer(source: .headset, at: 10.1, frames: 2400)
        if decision.releaseBuiltin { builtin.release() }
        #expect(!builtin.isAllocated && !builtin.isRunning && builtin.taps == 0)
        #expect(!b.buffer(source: .headset, at: 10.2, frames: 2400).releaseBuiltin)
    }

    @Test func noBridgeWhenDefaultIsBuiltin() {
        var b = bridge(.builtin)
        #expect(b.state == .switched && b.skipReason == "default_builtin")
        #expect(b.bridgeSource == "none")
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400).framesToFeed == 0)
        #expect(b.buffer(source: .headset, at: 10, frames: 2400).framesToFeed == 2400)
    }

    @Test func noBridgeWithoutBuiltin() {
        let b = bridge(builtin: false)
        #expect(b.state == .switched && b.skipReason == "no_builtin")
    }

    @Test func noBridgeForUSBInput() {
        let b = bridge(.other)
        #expect(b.state == .switched && b.skipReason == "not_bluetooth")
    }

    @Test func cancelDuringBridgeReleasesBoth() throws {
        let builtin = RedTeamEngine(), headset = RedTeamEngine()
        try builtin.start(device: .builtIn)
        let capture = CaptureLifecycle(engine: headset, scheduler: RedTeamClock())
        #expect(capture.beginRecording(at: 10))
        var b = bridge()
        #expect(builtin.isAllocated && headset.isAllocated)
        if b.cancel() { builtin.release() }
        capture.end(.cancel)
        #expect(!builtin.isAllocated && !headset.isAllocated)
        #expect(b.buffer(source: .builtin, at: 10.1, frames: 2400).framesToFeed == 0)
        #expect(b.buffer(source: .headset, at: 10.1, frames: 2400).framesToFeed == 0)
    }

    @Test func lateBuiltinBufferAfterSwitchIgnored() {
        var b = bridge()
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400).framesToFeed > 0)
        _ = b.buffer(source: .headset, at: 10.1, frames: 2400)
        #expect(b.buffer(source: .builtin, at: 10.2, frames: 2400).framesToFeed == 0)
    }

    @Test func warmingUntilHeadsetBuffer() {
        let capture = CaptureLifecycle(engine: RedTeamEngine(), scheduler: RedTeamClock())
        #expect(capture.beginRecording(at: 10))
        capture.bufferArrived(at: 10.1, source: .builtin)
        #expect(capture.warmup.phase == .warming)
        capture.bufferArrived(at: 11, source: .headset)
        #expect(capture.warmup.phase == .live && capture.warmup.warmMs == 1000)
    }

    @Test func stickyWarmZeroReleasesImmediately() {
        let engine = RedTeamEngine(), clock = RedTeamClock()
        let capture = CaptureLifecycle(engine: engine, scheduler: clock)
        #expect(capture.beginRecording(at: 10))
        #expect(engine.isAllocated && engine.isRunning)
        capture.end(.finished(.ok))
        #expect(!engine.isAllocated && !engine.isRunning) // no advance / grace period
    }

    @Test func recordingBoundaryDropsBothSourcesPreroll() {
        var b = CaptureBridge()
        b.start(defaultInput: .bluetooth, hasBuiltin: true)
        #expect(b.buffer(source: .builtin, at: 9, frames: 2400).framesToFeed == 0)
        b.recordingStarted(at: 10)
        #expect(b.buffer(source: .builtin, at: 9.95, frames: 2400).framesToFeed == 1200)
        #expect(b.buffer(source: .headset, at: 9.9, frames: 2400).framesToFeed == 0)
        #expect(b.buffer(source: .headset, at: 10.05, frames: 2400).framesToFeed == 2400)
    }

    @Test func headsetFlowingBeforeRecordingNeedsNoBridge() {
        var b = CaptureBridge()
        b.start(defaultInput: .bluetooth, hasBuiltin: true)
        #expect(b.buffer(source: .headset, at: 9, frames: 2400).releaseBuiltin)
        b.recordingStarted(at: 10)
        #expect(b.bridgeMs == 0)
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400).framesToFeed == 0)
        #expect(b.buffer(source: .headset, at: 10, frames: 2400).framesToFeed == 2400)
    }
    @Test func cancelledSessionBuffersCannotEnterNextRecording() {
        var b = bridge()
        let old = b.epoch
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400, epoch: old).framesToFeed == 2400)
        b.cancel()
        b.start(defaultInput: .bluetooth, hasBuiltin: true)
        b.recordingStarted(at: 11)
        #expect(b.buffer(source: .builtin, at: 11, frames: 2400, epoch: old).framesToFeed == 0)
        #expect(b.buffer(source: .headset, at: 11, frames: 2400, epoch: old).framesToFeed == 0)
        #expect(b.state == .builtinOnly)
        #expect(b.buffer(source: .builtin, at: 11, frames: 2400, epoch: b.epoch).framesToFeed == 2400)
    }

    @Test func wholeHeadsetOverlapIsDroppedBeforeFreshBufferFeeds() {
        var b = bridge()
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400).framesToFeed == 2400)
        let overlap = b.buffer(source: .headset, at: 10, frames: 2400)
        #expect(overlap.releaseBuiltin && overlap.dropFrames == 2400 && overlap.framesToFeed == 0)
        #expect(b.buffer(source: .headset, at: 10.1, frames: 2400).framesToFeed == 2400)
    }

    @Test func unavailableBuiltinFallsBackWithoutBlockingHeadset() {
        var b = bridge()
        b.builtinFailed()
        #expect(b.skipReason == "builtin_start_failed" && b.bridgeSource == "none")
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400).framesToFeed == 0)
        #expect(b.buffer(source: .headset, at: 10, frames: 2400).framesToFeed == 2400)
    }

    @Test func bridgeDurationUsesArrivalClockAndRetainsExactFrameContinuity() {
        var b = bridge()
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400).framesToFeed == 2400)
        // Headset input timestamp can precede delivery; warm time is arrival time.
        let switched = b.buffer(source: .headset, at: 10.08, frames: 1024, arrivedAt: 11)
        #expect(b.bridgeMs == 1000)
        #expect(switched.dropFrames == 480 && switched.framesToFeed == 544)
        let next = b.buffer(source: .headset, at: 10.08 + 1024.0 / 24000, frames: 1024)
        #expect(next.dropFrames == 0 && next.framesToFeed == 1024)
    }

}
