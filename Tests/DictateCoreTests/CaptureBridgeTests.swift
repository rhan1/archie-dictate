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

    // MARK: D0b — pre-roll from the first tap

    @Test func preBoundaryFramesGoToTheRingDedupedAcrossSources() {
        var b = CaptureBridge()
        b.start(defaultInput: .bluetooth, hasBuiltin: true)
        let first = b.buffer(source: .builtin, at: 9.0, frames: 2400)
        #expect(first.framesToFeed == 0 && first.framesToRing == 2400)
        // Headset already flowing before the second tap: overlap trimmed, rest ringed.
        let headset = b.buffer(source: .headset, at: 9.05, frames: 2400)
        #expect(headset.releaseBuiltin && headset.dropFrames == 1200 && headset.framesToRing == 1200)
        #expect(b.buffer(source: .builtin, at: 9.1, frames: 2400).framesToRing == 0)
        #expect(b.builtinFrames == 2400)
    }

    @Test func preRollMovesTheKeepPointBack150ms() {
        var b = CaptureBridge()
        b.start(defaultInput: .bluetooth, hasBuiltin: true)
        b.recordingStarted(at: 10, preRoll: 0.15)
        let straddling = b.buffer(source: .builtin, at: 9.8, frames: 2400) // 9.80 ..< 9.90
        #expect(straddling.dropFrames == 1200 && straddling.framesToFeed == 1200)
        // bridge_ms still counts from the second tap, not from the pre-roll point.
        _ = b.buffer(source: .headset, at: 9.9, frames: 2400, arrivedAt: 11.2)
        #expect(b.bridgeMs == 1200)
    }

    @Test func ringContinuityCarriesAcrossTheBoundary() {
        var b = CaptureBridge()
        b.start(defaultInput: .bluetooth, hasBuiltin: true)
        _ = b.buffer(source: .builtin, at: 9.9, frames: 2400) // ringed through 10.0
        b.recordingStarted(at: 9.95, preRoll: 0.15, keptFrames: 2400)
        #expect(b.firstKeptMs == 0)
        // An overlapping live headset buffer is trimmed against the ring's end, not the keep point.
        let headset = b.buffer(source: .headset, at: 9.95, frames: 2400)
        #expect(headset.dropFrames == 1200 && headset.framesToFeed == 1200)
    }

    @Test func bridgeWithoutBuiltinAudioSaysSo() {
        var silent = bridge()
        _ = silent.buffer(source: .headset, at: 10.1, frames: 2400)
        #expect(silent.bridgeSource == "builtin" && silent.reason == "builtin_no_audio")
        var real = bridge()
        _ = real.buffer(source: .builtin, at: 10, frames: 2400)
        _ = real.buffer(source: .headset, at: 10.1, frames: 2400)
        #expect(real.reason == nil && real.builtinFrames == 2400)
        #expect(bridge(.builtin).reason == "default_builtin")
    }

    // MARK: D-a — built-in selection keeps the headset's client format

    /// AUHAL after kAudioOutputUnitProperty_CurrentDevice: hardware follows the
    /// built-in mic (48 kHz) but the client format keeps the previous default
    /// (44.1 kHz headset). A rebuild re-creates the same stale pair.
    private final class StaleInputNode {
        var hardware = TapFormatPlan.Format(sampleRate: 48_000, channels: 1)
        var output = TapFormatPlan.Format(sampleRate: 44_100, channels: 1)
        var aligns = 0, rebuilds = 0
        var alignWorks = true
        func formats() -> (hardware: TapFormatPlan.Format, output: TapFormatPlan.Format) { (hardware, output) }
        func align() { aligns += 1; if alignWorks { output = hardware } }
        func rebuild() { rebuilds += 1; output = TapFormatPlan.Format(sampleRate: 44_100, channels: 1) }
    }

    @Test func builtinSelectionAlignsTheClientFormatInsteadOfFailing() throws {
        let node = StaleInputNode()
        let outcome = try TapFormatPlan.run(device: .builtIn, formats: node.formats,
                                            align: node.align, rebuild: node.rebuild)
        #expect(outcome == .ready(aligned: true, rebuilt: false))
        #expect(node.aligns == 1 && node.rebuilds == 0)
    }

    @Test func unalignableBuiltinFailsWithTheFormatPair() {
        let node = StaleInputNode()
        node.alignWorks = false
        var caught: TapFormatPlan.Mismatch?
        do { _ = try TapFormatPlan.run(device: .builtIn, formats: node.formats, align: node.align, rebuild: node.rebuild) }
        catch { caught = error as? TapFormatPlan.Mismatch }
        #expect(caught?.description == "format_mismatch hw=48000Hz/1ch out=44100Hz/1ch")
        #expect(node.aligns == 2 && node.rebuilds == 1) // bounded: align, rebuild, align, fail
    }

    @Test func defaultDeviceMismatchStillRebuildsOnceAndMatchingFormatsAreReady() throws {
        let node = StaleInputNode()
        node.output = node.hardware
        #expect(try TapFormatPlan.run(device: .default, formats: node.formats, align: node.align,
                                      rebuild: node.rebuild) == .ready(aligned: false, rebuilt: false))
        let stale = StaleInputNode()
        stale.output = TapFormatPlan.Format(sampleRate: 16_000, channels: 1)
        #expect(throws: TapFormatPlan.Mismatch.self) {
            try TapFormatPlan.run(device: .default, formats: stale.formats, align: stale.align, rebuild: stale.rebuild)
        }
        #expect(stale.aligns == 0 && stale.rebuilds == 1)
    }

    @Test func invalidHardwareFormatRebuildsThenFails() {
        let node = StaleInputNode()
        node.hardware = TapFormatPlan.Format(sampleRate: 0, channels: 0)
        #expect(throws: TapFormatPlan.Mismatch.self) {
            try TapFormatPlan.run(device: .builtIn, formats: node.formats, align: node.align, rebuild: node.rebuild)
        }
        #expect(node.aligns == 0 && node.rebuilds == 1)
    }
}
