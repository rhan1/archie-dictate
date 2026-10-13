import Foundation
import Testing
@testable import DictateCore

@Suite("CaptureBridge")
struct CaptureBridgeTests {
    /// v1.7: the headset takes over only after 150 ms of signal. 110 ms of earlier
    /// headset signal (never fed: the built-in carries it) lets the next buffer switch.
    private func prime(_ b: inout CaptureBridge, before time: TimeInterval) {
        #expect(!b.buffer(source: .headset, at: time - 0.11, frames: 2640).releaseBuiltin)
    }

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
        prime(&b, before: 10.1)
        let headset = b.buffer(source: .headset, at: 10.1, frames: 2400)
        #expect(headset.framesToFeed == 2400 && headset.releaseBuiltin)
        #expect(b.state == .switched && b.bridgeMs == 100 && b.bridgeSource == "builtin")
    }

    @Test func switchAtBufferBoundaryNoGapNoDuplicateBeyond100ms() {
        var b = bridge()
        #expect(b.buffer(source: .builtin, at: 10, frames: 2400).framesToFeed == 2400)
        prime(&b, before: 10.05)
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
        prime(&b, before: 10.1)
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
        prime(&b, before: 10.1)
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
        prime(&b, before: 9)
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
        prime(&b, before: 10)
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
        prime(&b, before: 10.08)
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
        prime(&b, before: 9.05)
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
        prime(&b, before: 9.9)
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
        prime(&b, before: 9.95)
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

    // MARK: v1.7 H1 — content-aware arbitration (eSCO drop → injected digital zeros)

    private func feedStarted() -> CaptureFeed {
        var feed = CaptureFeed()
        feed.start(defaultInput: .bluetooth, hasBuiltin: true)
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        return feed
    }
    private func tone(_ amplitude: Float, frames: Int = 2400) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(Double($0) * 0.13)) }
    }
    private let zeros = [Float](repeating: 0, count: 2400)

    @Test func digitalZeroHeadsetBufferDoesNotReleaseTheBuiltin() {
        var feed = feedStarted()
        #expect(feed.accept(tone(0.05), source: .builtin, at: 10).frames.count == 2400)
        let headset = feed.accept(zeros, source: .headset, at: 10.1)
        #expect(!headset.releaseBuiltin)
        #expect(headset.frames.isEmpty)
        #expect(feed.accept(tone(0.05), source: .builtin, at: 10.1).frames.count == 2400)
    }

    @Test func headsetSignalTakesOverOnlyAfter150ms() {
        var feed = feedStarted()
        _ = feed.accept(tone(0.05), source: .builtin, at: 10)
        _ = feed.accept(tone(0.05), source: .builtin, at: 10.1)
        let first = feed.accept(tone(0.05), source: .headset, at: 10.1)      // 100 ms of signal
        #expect(!first.releaseBuiltin && first.frames.isEmpty)
        let second = feed.accept(tone(0.05), source: .headset, at: 10.2)     // 200 ms ≥ 150 ms
        #expect(second.releaseBuiltin && second.frames.count == 2400)
        #expect(feed.bridge.state == .switched && feed.bridge.bridgeSource == "builtin")
    }

    /// v1.7 latched the fallback for the whole dictation (this test asserted signal from 12.5 s was
    /// ignored). v1.9 (L1, decision D7): a headset that recovers carries again — tonight's runs
    /// recovered ~0.4 s after the fallback and the distant built-in carried everything anyway.
    @Test func zerosFor1500msFallBackThenARecoveredHeadsetCarriesAgain() {
        var feed = feedStarted()
        var fed = 0, events: [CaptureBridge.Event] = []
        for i in 0..<40 {                                                   // 4 s of both sources
            let t = 10 + Double(i) * 0.1
            let b = feed.accept(tone(0.05), source: .builtin, at: t)
            let h = feed.accept(i < 25 ? zeros : tone(0.05), source: .headset, at: t)  // signal from 12.5 s
            fed += b.frames.count + h.frames.count
            events += [b.event, h.event].compactMap { $0 }
            #expect(!h.releaseBuiltin)
            if i < 26 { #expect(h.frames.isEmpty) }                        // 150 ms of signal before it carries
        }
        #expect(events == [.fallback, .recovered])
        #expect(feed.bridge.state == .switched && feed.bridge.bridgeSource == "builtin_fallback")
        #expect(feed.bridge.reason == "headset_digital_silence")
        #expect(fed == 40 * 2400)                                          // no gap, no duplicate
    }

    @Test func midDictationZerosSwitchBackToTheBuiltinWithoutGapOrDuplicate() {
        var feed = feedStarted()
        var timeline: [(CaptureBridge.Source, Int)] = [], events: [CaptureBridge.Event] = []
        for i in 0..<30 {
            let t = 10 + Double(i) * 0.1
            let b = feed.accept(tone(0.05), source: .builtin, at: t)
            // Headset: signal 10.0–11.0, then the link drops to zeros.
            let h = feed.accept(i < 10 ? tone(0.05) : zeros, source: .headset, at: t + 0.03)
            if !b.frames.isEmpty { timeline.append((.builtin, b.frames.count)) }
            if !h.frames.isEmpty { timeline.append((.headset, h.frames.count)) }
            events += [b.event, h.event].compactMap { $0 }
        }
        #expect(events == [.switchback])
        #expect(feed.bridge.switchbacks == 1 && feed.bridge.state == .fallback)
        #expect(feed.bridge.bridgeSource == "builtin")
        // v1.13 (L1): the built-in witnessed speech, so the switchback replays it from where the headset
        // went silent (11.03). Nothing the built-in heard is lost; the one zero buffer the headset fed
        // before the witness completed stays in as inserted silence (v1.12 kept the count at 3 s by
        // feeding 0.5 s of zeros IN PLACE of the built-in's speech).
        let total = timeline.reduce(0) { $0 + $1.1 }
        let headsetFed = timeline.filter { $0.0 == .headset }.reduce(0) { $0 + $1.1 }
        let builtinFed = timeline.filter { $0.0 == .builtin }.reduce(0) { $0 + $1.1 }
        #expect(headsetFed == 22_320)                                        // 10.20 → 11.13: its signal and one zero buffer
        #expect(builtinFed == 4_800 + 47_280)                                // 10.00 → 10.20, then 11.03 → 13.00: nothing skipped
        #expect(total - 3 * 24_000 <= 2_400)                                 // at most one buffer of inserted silence
        #expect(timeline.last?.0 == .builtin)
    }

    @Test func switchbackNeedsALiveBuiltin() {
        var feed = feedStarted()
        _ = feed.accept(tone(0.05), source: .headset, at: 10)
        _ = feed.accept(tone(0.05), source: .headset, at: 10.1)
        #expect(feed.bridge.state == .switched)
        feed.builtinFailed()
        for i in 2..<12 { _ = feed.accept(zeros, source: .headset, at: 10 + Double(i) * 0.1) }
        #expect(feed.bridge.state == .switched && feed.bridge.switchbacks == 0)
    }

    // MARK: v1.7 H2 — one headset restart per dictation

    @Test func silentHeadsetRequestsExactlyOneRestart() {
        var feed = feedStarted()
        var restarts: [Double] = []
        for i in 0..<60 {                                                   // 6 s of zeros
            let t = 10 + Double(i) * 0.1
            _ = feed.accept(tone(0.05), source: .builtin, at: t)
            if feed.accept(zeros, source: .headset, at: t).restartHeadset { restarts.append(t) }
            if i == 9 { feed.headsetRestarted() }                          // restart done at 10.9 s
        }
        #expect(restarts == [10.6])                                         // 700 ms after the first zero
        #expect(feed.bridge.restart?.result == "still_silent")
    }

    @Test func restartThatBringsSignalBackReportsIt() {
        var feed = feedStarted()
        var restarted = false
        for i in 0..<30 {
            let t = 10 + Double(i) * 0.1
            _ = feed.accept(tone(0.05), source: .builtin, at: t)
            let h = feed.accept(restarted ? tone(0.05) : zeros, source: .headset, at: t)
            if h.restartHeadset { feed.headsetRestarted(); restarted = true }
        }
        #expect(feed.bridge.restart?.result == "signal")
        #expect(feed.bridge.state == .switched)          // signal inside the 1.5 s window: headset takes over
    }

    @Test func secondSilentWindowAfterSwitchbackDoesNotRestartAgain() {
        var feed = feedStarted()
        var restarts = 0
        // zeros 0.8 s (restart #1) → signal 0.3 s → zeros 1 s
        let pattern = Array(repeating: false, count: 8) + Array(repeating: true, count: 3) + Array(repeating: false, count: 10)
        for (i, signal) in pattern.enumerated() {
            let t = 10 + Double(i) * 0.1
            _ = feed.accept(tone(0.05), source: .builtin, at: t)
            if feed.accept(signal ? tone(0.05) : zeros, source: .headset, at: t).restartHeadset { restarts += 1 }
        }
        #expect(restarts == 1)
    }

    @Test func headsetAsTheOnlySourceStillGetsItsOneRestart() {
        // No built-in to carry: zeros are all there is, so the one restart is free (review #4).
        var feed = CaptureFeed()
        feed.start(defaultInput: .bluetooth, hasBuiltin: false)
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        var restarts = 0, fed = 0
        for i in 0..<20 {
            let h = feed.accept(zeros, source: .headset, at: 10 + Double(i) * 0.1)
            if h.restartHeadset { restarts += 1 }
            fed += h.frames.count
        }
        #expect(restarts == 1 && fed == 20 * 2400)
        // A working headset-only link that pauses (DSP gates to zeros) is never cut by a restart.
        var working = CaptureFeed()
        working.start(defaultInput: .bluetooth, hasBuiltin: false)
        _ = working.recordingStarted(at: 10, preRoll: 0)
        var cut = 0
        for i in 0..<30 {
            let h = working.accept(i < 5 ? tone(0.05) : zeros, source: .headset, at: 10 + Double(i) * 0.1)
            if h.restartHeadset { cut += 1 }
        }
        #expect(cut == 0)
        var usb = CaptureFeed()
        usb.start(defaultInput: .other, hasBuiltin: true)                   // not Bluetooth: never
        _ = usb.recordingStarted(at: 10, preRoll: 0)
        #expect((0..<20).allSatisfy { !usb.accept(zeros, source: .headset, at: 10 + Double($0) * 0.1).restartHeadset })
    }

    @Test func failedRestartIsReportedAsFailed() {
        var feed = feedStarted()
        for i in 0..<8 {
            let t = 10 + Double(i) * 0.1
            _ = feed.accept(tone(0.05), source: .builtin, at: t)
            if feed.accept(zeros, source: .headset, at: t).restartHeadset { feed.headsetRestarted(started: false) }
        }
        #expect(feed.bridge.restart?.result == "failed")
        feed.cancel()
        #expect(feed.bridge.restart == nil && feed.bridge.switchbacks == 0) // a second stop logs nothing
    }

    // MARK: v1.7 review fixes — the headset engine fails or stops delivering

    @Test func headsetEngineFailureWhileTheBuiltinBridgesFallsBack() {
        var feed = feedStarted()
        _ = feed.accept(tone(0.05), source: .builtin, at: 10)
        let failed = feed.headsetFailed()
        #expect(failed.event == .fallback && failed.frames.isEmpty)
        #expect(feed.bridge.bridgeSource == "builtin_fallback" && feed.bridge.reason == "headset_engine_failed")
        #expect(feed.accept(tone(0.05), source: .builtin, at: 10.1).frames.count == 2400)
    }

    @Test func headsetEngineFailureAfterTakeoverResumesTheBuiltinWithoutAGap() {
        var feed = feedStarted()
        var total = 0
        for i in 0..<5 {                                                    // headset carries from 10.1
            let t = 10 + Double(i) * 0.1
            total += feed.accept(tone(0.05), source: .builtin, at: t).frames.count
            total += feed.accept(tone(0.05), source: .headset, at: t + 0.03).frames.count
        }
        _ = feed.accept(tone(0.05), source: .builtin, at: 10.5)             // into standby
        let failed = feed.headsetFailed()
        #expect(failed.event == .switchback)
        total += failed.frames.count
        total += feed.accept(tone(0.05), source: .builtin, at: 10.6).frames.count
        #expect(total == Int(0.7 * 24_000))                                // 10.0 → 10.7 contiguous
        var none = CaptureFeed()
        none.start(defaultInput: .bluetooth, hasBuiltin: false)
        #expect(none.headsetFailed().event == nil)                          // nothing carries: the owner fails
    }

    @Test func headsetBackAfterARecoveryGapTakesOverAgainWithoutLoss() {
        var feed = feedStarted()
        var total = 0, events: [CaptureBridge.Event] = []
        for i in 0..<40 {
            let t = 10 + Double(i) * 0.1
            let b = feed.accept(tone(0.05), source: .builtin, at: t)
            total += b.frames.count
            events += [b.event].compactMap { $0 }
            // Headset carries, stops for a 2 s rebuild (10.5–12.5), then returns with signal.
            if i < 5 || i >= 25 { total += feed.accept(tone(0.05), source: .headset, at: t).frames.count }
        }
        #expect(events == [.switchback])
        #expect(feed.bridge.state == .switched)                             // the recovered headset carries again
        #expect(total == 4 * 24_000)                                       // 10.0 → 14.0: nothing lost
    }

    @Test func headsetThatStopsDeliveringHandsBackOnBuiltinBuffers() {
        var feed = feedStarted()
        var timeline: [Int] = [], events: [CaptureBridge.Event] = []
        for i in 0..<20 {
            let t = 10 + Double(i) * 0.1
            let b = feed.accept(tone(0.05), source: .builtin, at: t)
            timeline.append(b.frames.count)
            events += [b.event].compactMap { $0 }
            if i < 5 {                                                      // headset IO stops at 10.53 (> 1 s → 11.6)
                let h = feed.accept(tone(0.05), source: .headset, at: t + 0.03)
                timeline.append(h.frames.count)
            }
        }
        #expect(events == [.switchback] && feed.bridge.switchbacks == 1)
        #expect(timeline.reduce(0, +) == 2 * 24_000)                       // 10.0 → 12.0 contiguous
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

    /// v1.9 L1: tonight the headset's second recovery delivered signal ~0.4 s after the 1.5 s
    /// digital-silence fallback (R1 10.321 → 10.785); v1.8 kept the distant built-in to the end.
    @Test func recoveredHeadsetRetakesADigitalSilenceFallback() {
        var b = bridge()
        var time = 10.0
        var events: [CaptureBridge.Event] = []
        func step(headsetPeak: Float) {
            if let e = b.buffer(source: .builtin, at: time, frames: 2400).event { events.append(e) }
            if let e = b.buffer(source: .headset, at: time, frames: 2400, peak: headsetPeak).event { events.append(e) }
            time += 0.1
        }
        for _ in 0..<16 { step(headsetPeak: 0) }
        #expect(events == [.fallback] && b.state == .fallback)
        for _ in 0..<2 { step(headsetPeak: 0.2) }
        #expect(events == [.fallback, .recovered])
        #expect(b.state == .switched && b.headsetRetakes == 1)
        let fed = b.buffer(source: .headset, at: time, frames: 2400, peak: 0.2)
        #expect(fed.framesToFeed == 2400)                            // the headset carries
        time += 0.1
        for _ in 0..<7 { step(headsetPeak: 0) }                      // zeros again: the built-in takes over
        #expect(events == [.fallback, .recovered, .switchback])
    }

}
