import Foundation
import Testing
@testable import DictateCore

@Suite("V1296BuiltinCore")
struct V1296BuiltinCoreTests {
    @Test func restart_budget_uses_a_sliding_five_second_window() {
        var policy = SoleBuiltinRestartPolicy()
        #expect(policy.judge(reason: .stale, at: 10) == .restart(.stale))
        #expect(policy.judge(reason: .format, at: 14.999) == .fail)
        #expect(policy.judge(reason: .lost, at: 15) == .restart(.lost))
        print("D GREEN restart_budget_sliding_window=1")
    }
    @Test func first_audio_clock_starts_when_start_returns() {
        var first = SoleBuiltinFirstAudio()
        first.startRequested(at: 100)
        _ = first.startReturned(at: 100.2)
        #expect(first.evaluate(at: 101.199) == nil)
        first.observe(frames: [CaptureBridge.silencePeak.nextUp], at: 101.2)
        #expect(first.evaluate(at: 101.2) == .ok)
        #expect(first.evaluate(at: 200) == nil)
        print("D GREEN first_audio_core_deadline=1")
    }
    @Test func sole_source_has_no_bridge_arbitration_and_default_is_unchanged() {
        var sole = CaptureFeed()
        let epoch = CaptureEpoch()
        sole.start(defaultInput: .bluetooth, hasBuiltin: true, epoch: epoch, sole: .builtin)
        #expect(sole.bridge.state == .builtinSole)
        #expect(!sole.health.bluetooth)
        _ = sole.recordingStarted(at: 0)
        let out = sole.accept(Array(repeating: Float(0.1), count: 2_400), source: .builtin, at: 0, epoch: epoch)
        #expect(out.frames.count == 2_400)
        #expect(!out.releaseBuiltin && !out.restartHeadset && out.event == nil)
        for input in [CaptureBridge.DefaultInput.builtin, .bluetooth, .other] {
            var legacy = CaptureFeed(), explicitDefault = CaptureFeed()
            legacy.start(defaultInput: input, hasBuiltin: true, epoch: epoch)
            explicitDefault.start(defaultInput: input, hasBuiltin: true, epoch: epoch, sole: nil)
            #expect(legacy.bridge.state == explicitDefault.bridge.state)
            #expect(legacy.health.bluetooth == explicitDefault.health.bluetooth)
        }
        print("D GREEN sole_feed_and_default_parameter_control=1")
    }
}
