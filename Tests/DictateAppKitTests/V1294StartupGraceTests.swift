import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

/// 1.29.4 (H): a slow first microphone start on a non-Bluetooth input is not `mic_dead`.
/// 2026-11-07 08:24 (Archie 62.5.4, default built-in input, no headset): `engine_start_ms=2011`, then
/// `ptt_capture_failed=mic_dead frames=0` at boundary + 2.0 s, as the start returned. The next capture started in ≈80 ms.
///
/// The production path the recorder drives: `AudioRecorder.startupPolicy` (what `configureBridge` passes) →
/// `CaptureFeed.start(…, startupPolicy:)` → `CaptureHealth`, the recorder's `headsetStartInFlight` calls
/// (`CaptureFeed.headsetStart(inFlight:at:)`), its buffers (`CaptureFeed.accept`) and its independent 100 ms
/// health clock (`CaptureFeed.tick`). The recorder's order is Archie's: the boundary (`resetCapture`) BEFORE the
/// start. Times are host-clock seconds; the boundary is 10.0 and every reported time is relative to it.
@Suite("V1294StartupGraceTests")
struct V1294StartupGraceTests {
    static let boundary: TimeInterval = 10
    static let chunk = 2_400                                  // 100 ms at 24 kHz
    static let tone: [Float] = (0..<chunk).map { 0.05 * Float(sin(Double($0) * 0.13)) + 0.0005 }
    static let zeros = [Float](repeating: 0, count: chunk)

    enum Frames { case none, tone, zeros }

    struct Scenario {
        var bluetooth = false
        /// The capture's own start (`start(device:)`); false = a route apply/retry's start.
        var initialStart = true
        /// Seconds after the boundary at which the first native start returns (nil: wedged, never returns).
        var startReturned: TimeInterval? = 0.08
        /// First buffer (s after the boundary) and what the input then delivers every 100 ms.
        var firstBuffer: TimeInterval?
        var frames: Frames = .tone
        /// A retry/re-attach start called (s) and still in flight to the end.
        var retryInFlightAt: TimeInterval?
        /// A second recording boundary on the same capture (a re-listen) at this offset.
        var relistenAt: TimeInterval?
        var seconds: TimeInterval = 6
    }

    struct Result {
        var failedAt: TimeInterval?
        var failures = 0
        var failure: CaptureFailure?
        var warns: [(TimeInterval, CaptureHealth.Reason)] = []
        var notes: [String] = []
        var keptFrames = 0
        var policy: CaptureHealth.StartupPolicy = .standard
        var failedText: String { failedAt.map { String(format: "%.1f", $0) } ?? "never" }
    }

    static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
    static func at(_ ms: Int) -> TimeInterval { boundary + Double(ms) / 1000 }

    /// Runs one capture on a 1 ms event clock: start return, buffers (arrival times) and the 100 ms health tick.
    static func run(_ s: Scenario) -> Result {
        var feed = CaptureFeed()
        var result = Result()
        let policy = AudioRecorder.startupPolicy(initialStart: s.initialStart, bluetooth: s.bluetooth)
        result.policy = policy
        // configureBridge: the feed starts with the recorder's policy, then re-applies the existing boundary.
        // No built-in bridge (non-Bluetooth: `default_builtin`; Bluetooth: `no_builtin`): the headset client carries.
        feed.start(defaultInput: s.bluetooth ? .bluetooth : .builtin, hasBuiltin: false, startupPolicy: policy)
        _ = feed.recordingStarted(at: boundary, preRoll: 0)
        feed.sourceStarted(.headset, at: boundary)
        feed.headsetStart(inFlight: true)                    // headsetStartInFlight: the native start begins
        let returnMs = s.startReturned.map(ms)
        let firstMs = s.firstBuffer.map(ms)
        let end = ms(s.seconds)
        for t in 1...end {
            let now = at(t)
            if t == returnMs { feed.headsetStart(inFlight: false, at: now) }
            if let retry = s.retryInFlightAt.map(ms), t == retry { feed.headsetStart(inFlight: true) }
            if let relisten = s.relistenAt.map(ms), t == relisten { _ = feed.recordingStarted(at: now, preRoll: 0) }
            if let firstMs, t >= firstMs, (t - firstMs) % 100 == 0, result.failedAt == nil, s.frames != .none {
                let out = feed.accept(s.frames == .tone ? tone : zeros, source: .headset, at: now - 0.1, arrivedAt: now)
                result.keptFrames += out.frames.count
            }
            guard t % 100 == 0 else { continue }
            let out = feed.tick(at: now)
            result.notes += out.notes
            if let warn = out.warn { result.warns.append((Double(t) / 1000, warn)) }
            if let failure = out.failure {
                result.failures += 1
                if result.failedAt == nil { result.failedAt = Double(t) / 1000; result.failure = failure }
            }
        }
        return result
    }

    // MARK: the 08:24 trace

    @Test func slowStartReturningAt2011WithFirstBufferAt2120Survives() {
        let r = Self.run(Scenario(startReturned: 2.011, firstBuffer: 2.12))
        print("H \(r.failedAt == nil ? "GREEN" : "RED") slow_start start_returned=2.011 first_buffer=2.12 "
              + (r.failedAt == nil ? "failed=never" : "failed_at=\(r.failedText)")
              + " failures=\(r.failures) kept_frames=\(r.keptFrames) policy=\(r.policy.rawValue)")
        #expect(r.policy == .nonBluetoothGrace)
        #expect(r.failedAt == nil && r.failures == 0)
        #expect(r.keptFrames > 30 * Self.chunk)               // the audio after 2.12 s entered the capture
    }

    @Test func warnAt1sStillFiresDuringTheGrace() {
        let r = Self.run(Scenario(startReturned: 2.011, firstBuffer: 2.12))
        let noInput = r.warns.filter { $0.1 == .noInput }
        print("H CONTROL warn_1s fired=\(noInput.count) at=\(noInput.first.map { String(format: "%.1f", $0.0) } ?? "-")"
              + " note=\(r.notes.filter { $0 == "health=warn reason=no_input" }.count)")
        #expect(noInput.count == 1 && noInput.first?.0 == 1.1)  // first tick past builtinGrace (1.0 s)
        #expect(r.notes.contains("health=warn reason=no_input"))
    }

    // MARK: controls (unchanged before and after)

    @Test func promptStartWithNoFramesStillFailsAt2s() {
        let r = Self.run(Scenario(startReturned: 0.08, firstBuffer: nil))
        print("H CONTROL prompt_start_no_frames failed_at=\(r.failedText) failures=\(r.failures)"
              + " note=\(r.failure?.note ?? "-")")
        #expect(r.failedAt == 2.0 && r.failures == 1)
        #expect(r.failure?.reason == .micDead && r.failure?.health == .noInput && r.failure?.framesKept == 0)
        // Positive control: the same prompt start with frames from 0.2 s never fails.
        let live = Self.run(Scenario(startReturned: 0.08, firstBuffer: 0.2))
        print("H CONTROL prompt_start_frames failed=\(live.failedText) kept_frames=\(live.keptFrames)")
        #expect(live.failedAt == nil && live.keptFrames > 0)
    }

    @Test func wedgedStartFailsAtTheCap() {
        let r = Self.run(Scenario(startReturned: nil, firstBuffer: nil))
        print("H CONTROL wedged_start failed_at=\(r.failedText) failures=\(r.failures)")
        #expect(r.failedAt == 4.0 && r.failures == 1)
        #expect(r.failure?.reason == .micDead && r.failure?.health == .noInput)
    }

    @Test func returnedLateAndNothingArrivesFailsOneSecondLater() {
        // A start returning at 2.5 s that then delivers nothing: 2.5 + 1.0 = 3.5 s.
        let late = Self.run(Scenario(startReturned: 2.5, firstBuffer: nil))
        // A start returning at 3.5 s: capped at 4.0 s from the original boundary.
        let capped = Self.run(Scenario(startReturned: 3.5, firstBuffer: nil))
        print("H CONTROL returned_late_no_frames returned=2.5 failed_at=\(late.failedText); returned=3.5 failed_at=\(capped.failedText)")
        #expect(late.failedAt == 3.5 && late.failures == 1)
        #expect(capped.failedAt == 4.0 && capped.failures == 1)
    }

    @Test func zerosOnlyStillFailAt2s() {
        let r = Self.run(Scenario(startReturned: 0.08, firstBuffer: 0.1, frames: .zeros))
        // Exact zeros after a slow start end the grace for good: v1.8's deadline (the boundary + 2.0) applies.
        let slow = Self.run(Scenario(startReturned: 2.011, firstBuffer: 2.12, frames: .zeros))
        print("H CONTROL zeros_only failed_at=\(r.failedText) health=\(r.failure?.health?.rawValue ?? "-");"
              + " after_slow_start failed_at=\(slow.failedText)")
        #expect(r.failedAt == 2.0 && r.failures == 1)
        #expect(slow.failedAt == 2.2 && slow.failures == 1)
    }

    @Test func bluetoothKeepsTheV127Rule() {
        let stuck = Self.run(Scenario(bluetooth: true, startReturned: nil, firstBuffer: nil))
        let early = Self.run(Scenario(bluetooth: true, startReturned: 0.5, firstBuffer: nil))
        let slow = Self.run(Scenario(bluetooth: true, startReturned: 2.011, firstBuffer: 2.12))
        let line = "H CONTROL bluetooth_4s unchanged stuck=\(stuck.failedText) returned_0.5=\(early.failedText)"
            + " slow_start=\(slow.failedText) policy=\(stuck.policy.rawValue)"
        print(line)
        #expect(stuck.policy == .standard)
        #expect(stuck.failedAt == 4.0 && early.failedAt == 4.0 && slow.failedAt == nil)
    }

    @Test func retryRouteApplyAndRelistenNeverRenewTheGrace() {
        // A retry start in flight after the first start returned promptly: still 2.0 s.
        let retry = Self.run(Scenario(startReturned: 0.08, firstBuffer: nil, retryInFlightAt: 0.5))
        // A re-listen boundary at 1.5 s while the first start is wedged: the cap stays 4.0 s from the ORIGINAL boundary.
        let relisten = Self.run(Scenario(startReturned: nil, firstBuffer: nil, relistenAt: 1.5))
        // A route apply/retry's start (`initialStart: false`) gets no grace: today's 2.0 s.
        let apply = Self.run(Scenario(initialStart: false, startReturned: 2.011, firstBuffer: 2.12))
        print("H CONTROL no_renewal retry/re-listen keeps the original boundary retry_failed_at=\(retry.failedText)"
              + " relisten_failed_at=\(relisten.failedText) route_apply_policy=\(apply.policy.rawValue)"
              + " route_apply_failed_at=\(apply.failedText)")
        #expect(retry.failedAt == 2.0)
        #expect(relisten.failedAt == 4.0)
        #expect(apply.policy == .standard && apply.failedAt == 2.0)
    }

    @Test func recorderPolicyIsExplicitAndNeverSetsBluetooth() {
        var feed = CaptureFeed()
        feed.start(defaultInput: .builtin, hasBuiltin: true,
                   startupPolicy: AudioRecorder.startupPolicy(initialStart: true, bluetooth: false))
        print("H CONTROL policy builtin=\(feed.health.startupPolicy.rawValue) bluetooth_flag=\(feed.health.bluetooth)"
              + " bt=\(AudioRecorder.startupPolicy(initialStart: true, bluetooth: true).rawValue)"
              + " apply=\(AudioRecorder.startupPolicy(initialStart: false, bluetooth: false).rawValue)")
        #expect(feed.health.startupPolicy == .nonBluetoothGrace && !feed.health.bluetooth)
        #expect(AudioRecorder.startupPolicy(initialStart: true, bluetooth: true) == .standard)
        #expect(AudioRecorder.startupPolicy(initialStart: false, bluetooth: false) == .standard)
        // The default feed (every other caller) keeps the standard policy.
        var plain = CaptureFeed()
        plain.start(defaultInput: .other, hasBuiltin: false)
        #expect(plain.health.startupPolicy == .standard)
    }
}
