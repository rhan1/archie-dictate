import Foundation
import Testing
@testable import DictateCore

/// v1.13 cross-vendor review (codex gpt-6.1-sol, 10-13 16:21–16:50, /tmp/dictate-v11-review/findings.md):
/// each reproducer that proved a defect at 70baafe, asserting the corrected behaviour.
@Suite("ReviewRegression")
struct ReviewRegressionTests {
    func batch(_ value: Float, _ count: Int = 2400) -> [Float] { Array(repeating: value, count: count) }

    /// #1: before the second tap, a takeover that needs already-arrived headset history puts it in the
    /// pre-roll ring — none leaks to the dictation, none of the takeover buffer is cut.
    @Test func preTapHistoryGoesToTheRingWhole() {
        var f = CaptureFeed()
        f.start(defaultInput: .bluetooth, hasBuiltin: true)
        _ = f.accept(batch(0.002, 1200), source: .builtin, at: 0)
        _ = f.accept(batch(0.02), source: .headset, at: 0)
        let takeover = f.accept(batch(0.03), source: .headset, at: 0.1)
        let kept = f.recordingStarted(at: 0.2)
        #expect(takeover.releaseBuiltin && takeover.frames.isEmpty)
        #expect(kept.count == 3600 && kept.filter { $0 == 0.03 }.count == 2400)
    }

    /// #3: a replay older than standby holds is cut to it and SAYS so.
    @Test func replayOlderThanStandbyIsNoted() {
        var f = CaptureFeed()
        f.start(defaultInput: .bluetooth, hasBuiltin: true)
        f.setWarmRoute()
        _ = f.recordingStarted(at: 0, preRoll: 0)
        var notes: [String] = []
        for i in 0..<420 {
            let t = Double(i) / 100
            notes += f.accept(batch(i >= 400 ? 0.03 : 0.002, 240), source: .builtin, at: t, arrivedAt: t + 0.01).notes
            notes += f.accept(batch(i < 20 ? 0.02 : 0, 240), source: .headset, at: t, arrivedAt: t + 0.01).notes
            notes += f.tick(at: t + 0.01).notes
        }
        #expect(notes.contains { $0.hasPrefix("bridge_replay_truncated_ms=") })
    }

    /// #5: a warm first-buffer takeover still gets aligned later; the relabel trims nothing.
    @Test func alignmentLandsAfterAnEarlyTakeoverWithoutTrimming() {
        var f = CaptureFeed()
        f.start(defaultInput: .bluetooth, hasBuiltin: true)
        f.setWarmRoute()
        _ = f.recordingStarted(at: 0, preRoll: 0)
        var seed: UInt64 = 7
        var levels: [Float] = []
        for _ in 0..<200 {                                          // 10 ms syllable-ish levels, not periodic
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            levels.append((seed >> 40) % 3 == 0 ? 0.001 : Float((seed >> 33) % 1000) / 2000 + 0.05)
        }
        let lag = 5                                                 // 50 ms: headset content trails its stamps
        var headsetFed = 0, headsetDelivered = 0, takeover: Int?
        for i in 0..<200 {
            let t = Double(i) / 100
            _ = f.accept(batch(levels[i] * 0.126 + 0.001, 240), source: .builtin, at: t, arrivedAt: t + 0.01)
            let h = f.accept(batch(i >= lag ? levels[i - lag] : 0, 240), source: .headset, at: t, arrivedAt: t + 0.01)
            if h.releaseBuiltin { takeover = i }
            if takeover != nil, f.carrying == .headset, i > (takeover ?? 0) { headsetDelivered += 240; headsetFed += h.frames.count }
        }
        #expect(takeover.map { $0 <= lag + 1 } == true)
        #expect(f.aligned && abs(f.headsetLag - 0.05) <= 0.0051)
        #expect(headsetFed == headsetDelivered)
    }

    /// #6: a witnessed replay never reaches behind the recording boundary.
    @Test func witnessReplayStopsAtTheRecordingBoundary() {
        var f = CaptureFeed()
        f.start(defaultInput: .bluetooth, hasBuiltin: true)
        f.setWarmRoute()
        for i in 0..<50 {
            let t = Double(i) / 100
            _ = f.accept(batch(0.002, 240), source: .builtin, at: t)
            _ = f.accept(batch(i == 0 ? 0.02 : 0, 240), source: .headset, at: t)
        }
        #expect(f.recordingStarted(at: 0.5).count == 3600)
        var replay: [Float] = []
        for i in 50..<70 {
            let t = Double(i) / 100
            let out = f.accept(batch(i < 55 ? 0.002 : 0.03, 240), source: .builtin, at: t)
            if out.event == .switchback { replay = out.frames }
            _ = f.accept(batch(0, 240), source: .headset, at: t)
        }
        #expect(!replay.isEmpty && replay.count <= 8400)
    }

    /// #7: a warm running-engine notification folded into a stopped-engine obligation needs signal.
    @Test func coalescedWarmNotificationNeedsSignal() {
        var warm = HeadsetIOGuard(bluetooth: true, warmRoute: true)
        #expect(warm.configurationChanged(at: 1, engineRunning: false) == .reattach)
        _ = warm.configurationChanged(at: 1.1, engineRunning: true)
        warm.headsetFrames(2400, peak: 0, at: 1.2)
        #expect(warm.observe(at: 1.3, engineRunning: true) == .pending(until: 2))
        #expect(warm.obligation?.reason == .formatChanged)
    }

    /// #8: a hole in the built-in's timestamps is not speech.
    @Test func witnessNeedsConsecutiveSpeech() {
        var b = CaptureBridge()
        b.start(defaultInput: .bluetooth, hasBuiltin: true)
        b.setWarmRoute()
        b.recordingStarted(at: 0)
        _ = b.buffer(source: .headset, at: 0, frames: 2400, peak: 0.02)
        _ = b.buffer(source: .headset, at: 1, frames: 7200, peak: 0)
        _ = b.buffer(source: .builtin, at: 1, frames: 1200, peak: 0.02)
        #expect(b.buffer(source: .builtin, at: 1.20, frames: 1200, peak: 0.02).event == nil)
    }

    /// #9: an estimate needs every lag candidate evaluable.
    @Test func incompleteLagCoverageGivesNoEstimate() {
        func periodic(_ bins: Int) -> [Float] { (0..<bins).flatMap { batch($0 % 10 < 6 ? 0.1 : 0, 120) } }
        #expect(SpliceAligner.estimate(headset: periodic(40), headsetStart: 0, builtin: periodic(36), builtinStart: 0) == nil)
    }

    /// #10: staleness is IO age — the lag shift does not age a buffer that just arrived.
    @Test func staleCheckIgnoresTheLagShift() {
        var b = CaptureBridge()
        b.start(defaultInput: .bluetooth, hasBuiltin: true)
        b.setWarmRoute()
        b.setHeadsetLag(0.25)
        b.recordingStarted(at: 9)
        _ = b.buffer(source: .headset, at: 10 - 0.25, frames: 2400, arrivedAt: 11, peak: 0.02)
        #expect(b.buffer(source: .builtin, at: 11, frames: 240, arrivedAt: 11.01, peak: 0.002).event == nil)
    }
}
