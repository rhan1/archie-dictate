import Foundation
import Testing
import DictateCore

/// v1.11 L4 (GPT-6 review §B): R4 10-13 07:07:09 (session 41f98dbd) was a headset TAKEOVER —
/// `bridge_ms=1106 bridge_src=builtin` at 07:07:10.312006, five speech sections, zero built-in frames
/// after fallback — and was read as "built-in from start", and its restart as `still_silent`.
/// Lines marked `// v1.11-api` use v1.11 API; the RED run on v1.10 strips them.
@Suite("CarrierTelemetry")
struct CarrierTelemetryTests {
    private func tone(frames: Int) -> [Float] { (0..<frames).map { 0.05 * Float(sin(Double($0) * 0.13)) } }

    /// R4's timing from the second tap (10.0): the built-in bridges 1.106 s, the headset delivers
    /// 0.81 s of zeros (a restart is requested at 0.7 s and never runs), then signal; after 0.15 s
    /// of signal it takes over and carries to 15.110 s.
    private func replayR4() -> CaptureFeed {
        var feed = CaptureFeed()
        feed.start(defaultInput: .bluetooth, hasBuiltin: true)
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        _ = feed.accept(tone(frames: 26_544), source: .builtin, at: 10)                  // 10.000–11.106
        let zeros = feed.accept([Float](repeating: 0, count: 19_440), source: .headset, at: 10)  // 10.000–10.810
        #expect(zeros.restartHeadset)                                                   // requested, never run
        _ = feed.accept(tone(frames: 3_600), source: .headset, at: 10.81)               // takeover
        var t = 10.96
        while t < 25.11 - 1e-9 {
            let frames = min(2_400, Int(((25.11 - t) * 24_000).rounded()))
            _ = feed.accept(tone(frames: frames), source: .headset, at: t)
            t += Double(frames) / 24_000
        }
        return feed
    }

    /// The v1.10 fields on R4: `bridge_src=builtin` while the headset carries — why they misled.
    @Test func r4LegacyBridgeSourceNamesTheBridgeNotTheCarrier() {
        let feed = replayR4()
        #expect(feed.bridge.state == .switched)
        #expect(feed.bridge.bridgeSource == "builtin")
        #expect(feed.bridge.bridgeMs == nil || feed.bridge.bridgeMs! >= 0)
    }

    /// RED on v1.10 (`still_silent`): a restart that never ran is not a carrier verdict.
    @Test func r4SkippedRestartIsNotStillSilent() {
        #expect(replayR4().bridge.restart?.result == "skipped")
    }

    /// GREEN: R4 reports the headset takeover and the per-source intervals.
    @Test func r4ReportsHeadsetTakeoverAndIntervals() {
        let feed = replayR4()
        #expect(feed.bridge.carrierNote(endMs: 15_110) == "builtin:0-1106,headset:1106-15110") // v1.11-api
        #expect(feed.bridge.headsetCarriedMs(endMs: 15_110) == 14_004) // v1.11-api
    }

    /// Positive control for the ledger: a dictation the built-in carries throughout reports 0 ms of headset.
    @Test func builtinThroughoutCarriesNoHeadset() {
        var feed = CaptureFeed()
        feed.start(defaultInput: .bluetooth, hasBuiltin: true)
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        _ = feed.accept(tone(frames: 24_000), source: .builtin, at: 10)
        #expect(feed.bridge.carrierNote(endMs: 1_000) == "builtin:0-1000") // v1.11-api
        #expect(feed.bridge.headsetCarriedMs(endMs: 1_000) == 0) // v1.11-api
    }

    /// A restart that ran and brought no signal is still `still_silent`; one that brought signal is `signal`.
    @Test func restartThatRanKeepsItsVerdict() {
        var feed = CaptureFeed()
        feed.start(defaultInput: .bluetooth, hasBuiltin: true)
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        _ = feed.accept(tone(frames: 24_000), source: .builtin, at: 10)
        _ = feed.accept([Float](repeating: 0, count: 19_440), source: .headset, at: 10)
        feed.headsetRestarted()
        #expect(feed.bridge.restart?.result == "still_silent")
        _ = feed.accept(tone(frames: 3_600), source: .headset, at: 10.81)
        #expect(feed.bridge.restart?.result == "signal")
    }

    /// A non-Bluetooth default input carries alone (no bridge): `default_input`, no headset ms.
    @Test func nonBluetoothDefaultInputIsNotAHeadset() {
        var feed = CaptureFeed()
        feed.start(defaultInput: .builtin, hasBuiltin: true)
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        _ = feed.accept(tone(frames: 24_000), source: .headset, at: 10)
        #expect(feed.bridge.carrierNote(endMs: 1_000) == "default_input:0-1000") // v1.11-api
        #expect(feed.bridge.headsetCarriedMs(endMs: 1_000) == 0) // v1.11-api
    }
}
