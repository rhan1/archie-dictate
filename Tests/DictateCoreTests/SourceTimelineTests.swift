import Testing
@testable import DictateCore

/// v1.12 L1: per-source frame timestamps — the session line's `carrier=` / `headset_carried_ms=`.
@Suite("SourceTimeline")
struct SourceTimelineTests {
    static func tone(_ n: Int, _ level: Float = 0.2) -> [Float] { [Float](repeating: level, count: n) }

    @Test func runsJoinPerSourceAndSplitOnHandoverOrGap() {
        var timeline = SourceTimeline()
        timeline.start(at: 100)
        timeline.append(.builtin, frames: 2_400, at: 100.0)
        timeline.append(.builtin, frames: 2_400, at: 100.1 + 0.01)   // 10 ms jitter: same run
        timeline.append(.headset, frames: 4_800, at: 100.21)
        timeline.append(.headset, frames: 2_400, at: 100.6)          // 190 ms gap: a new run
        #expect(timeline.carrierNote == "carrier=builtin:0-210,headset:210-410,headset:600-700")
        #expect(timeline.headsetCarriedMs == 300 && timeline.builtinCarriedMs == 200)
        #expect(timeline.note == "carrier=builtin:0-210,headset:210-410,headset:600-700 headset_carried_ms=300")
    }

    @Test func truncationNeverExtendsARunOverMissingTime() {
        var timeline = SourceTimeline()
        timeline.start(at: 0)
        for i in 0..<(SourceTimeline.maxRuns + 5) {
            timeline.append(i % 2 == 0 ? .builtin : .headset, frames: 240, at: Double(i) * 0.1)
        }
        #expect(timeline.truncated && timeline.unlistedRuns == 5 && timeline.runs.count == SourceTimeline.maxRuns)
        #expect(timeline.carrierNote.hasSuffix(",+5"))
        #expect(timeline.runs.last.map { Int(($0.end - $0.start) * 1000 + 0.5) } == 10)   // still 10 ms, not stretched
        #expect(timeline.headsetFrames + timeline.builtinFrames == 240 * (SourceTimeline.maxRuns + 5))
        #expect(timeline.note.hasSuffix(" carrier_truncated=1"))
    }

    @Test func nothingKeptIsNone() {
        var timeline = SourceTimeline()
        timeline.start(at: 5)
        #expect(timeline.note == "carrier=none headset_carried_ms=0")
    }

    /// R4 — session 41f98dbd, 2026-10-13 07:07:09.196170 (+08) start; N:59 headset_signal_start
    /// 07:07:10.311590; N:60 `bridge_ms=1106 bridge_src=builtin` .312006; N:66 end 07:07:24.952659
    /// `recording_ms=15110`, `builtin_frames_after_fallback=0`. The `bridge_ms` message is emitted ON
    /// TAKEOVER and `bridgeSource` stays "builtin" (CaptureBridge.swift:91–100,175–182): the live
    /// results table read it as "builtin (from start)" and "headset FAIL 0/7". The carrier comes
    /// from the frames: built-in to the handover, then the headset to the end.
    @Test func r4ReplayReportsHeadsetTakeoverAndSourceIntervals() {
        let boundary = 9.205738                                  // s after 07:07:00 (tap2_to_first_kept .205738)
        var feed = CaptureFeed()
        feed.start(defaultInput: .bluetooth, hasBuiltin: true)
        let step = 0.05, n = 1_200                               // 50 ms batches at 24 kHz, delivered at their end
        let end = boundary + 15.110
        // Built-in from 150 ms before the boundary; the headset's clock is 6 ms offset, first buffer
        // at +218 ms (first_buffer_ms=218), digital zeros until 0.956 s, then signal: its third
        // signal batch completes `takeoverSignal` and arrives at +1.106 s (bridge_ms=1106).
        var batches: [(source: CaptureBridge.Source, start: Double, level: Float)] = []
        var t = boundary - 0.15
        while t + step <= end + 1e-9 { batches.append((.builtin, t, 0.2)); t += step }
        t = boundary + 0.206
        while t + step <= end + 1e-9 { batches.append((.headset, t, t >= boundary + 0.956 - 1e-9 ? 0.05 : 0)); t += step }
        batches.sort { $0.start + step < $1.start + step }
        var takeoverMs: Int?
        var started = false
        for batch in batches {
            let arrival = batch.start + step
            if !started, arrival >= boundary { _ = feed.recordingStarted(at: boundary); started = true }
            let out = feed.accept(Self.tone(n, batch.level), source: batch.source, at: batch.start, arrivedAt: arrival)
            if out.releaseBuiltin { takeoverMs = Int(((arrival - boundary) * 1000).rounded()) }
        }
        #expect(takeoverMs == 1106 && feed.bridge.bridgeMs == 1106)
        #expect(feed.bridge.bridgeSource == "builtin")           // the misleading label, unchanged
        #expect(feed.bridge.state == .switched && feed.carrying == .headset)
        // By FRAME time the handover is at 1100 ms: the built-in had already been fed through 1.100 s
        // when the takeover batch (1.056–1.106) arrived; only its last 6 ms entered.
        #expect(feed.timeline.carrierNote == "carrier=builtin:0-1100,headset:1100-15106")
        #expect(feed.timeline.headsetCarriedMs == 14006 && feed.timeline.lastSource == .headset)
        #expect(feed.bridge.builtinFramesAfterFallback == 0)
    }
}
