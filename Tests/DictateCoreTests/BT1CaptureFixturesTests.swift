import Foundation
import Testing
@testable import DictateCore

/// BT1 (v1.19): Bluetooth pre-roll, built-in fallback and the no-built-in / lid-closed device sets,
/// through the production `CaptureFeed` (bridge, pre-roll ring, health clock) on a fake sample clock.
/// These fixtures certify POLICY — which source's frames enter the dictation — not acoustics: the
/// "world" is a synthetic word (constant level) over a room floor, and each source only delivers the
/// samples that fall inside its live interval. No device, no audio.
@Suite("BT1CaptureFixtures")
struct BT1CaptureFixturesTests {
    static let rate = 24_000.0
    /// 50 ms per delivery.
    static let chunk = 1_200
    /// The second tap (recording boundary), as a sample index: 10 s.
    static let boundary = 240_000
    /// The first word: spoken from boundary + 50 ms for 400 ms.
    static let wordStart = boundary + 1_200
    static let wordFrames = 9_600
    static let wordLevel: Float = 0.2
    /// The built-in hears the speaker from a distance (WAVInjectedRecorder.distantGain).
    static let distant: Float = 0.126
    /// The room floor: non-zero (never digital silence), far below any word.
    static let floorLevel: Float = 0.001
    /// A delivered sample at or above this level carries the word (distant word = 0.0252).
    static let wordThreshold: Float = 0.02

    static func time(_ n: Int) -> TimeInterval { Double(n) / rate }
    static func ms(_ n: Int) -> Int { Int((Double(n) / rate * 1000).rounded()) }

    /// What a live source hears at sample `n`.
    static func heard(_ n: Int, gain: Float) -> Float {
        n >= wordStart && n < wordStart + wordFrames ? wordLevel * gain : floorLevel
    }

    struct Source {
        /// First sample index the source delivers (its link / unit is up).
        var from: Int
        var gain: Float = 1
        /// Exact zeros (a dropped eSCO link, or a lid-closed built-in) before this sample index.
        var zerosUntil: Int?
        /// Exact zeros for the whole run.
        var allZeros = false
        func frames(_ n0: Int) -> [Float] {
            (n0..<(n0 + BT1CaptureFixturesTests.chunk)).map { n in
                if allZeros || n < (zerosUntil ?? Int.min) { return 0 }
                return BT1CaptureFixturesTests.heard(n, gain: gain)
            }
        }
    }

    struct Run {
        var delivered: [Float] = []
        var events: [CaptureBridge.Event] = []
        var restartRequests = 0
        var fallbackRefused = 0
        var notes: [String] = []
        var failure: CaptureFailure?
        var feed = CaptureFeed()
        var wordDelivered: Int { delivered.filter { $0 >= BT1CaptureFixturesTests.wordThreshold }.count }
    }

    /// Drives both sources in arrival order (built-in first within a 50 ms slot), the boundary at
    /// `boundary`, and the 100 ms health clock after it, until `end` or a `mic_dead` failure.
    static func run(hasBuiltin: Bool, warm: Bool = false, builtin: Source?, headset: Source, end: Int) -> Run {
        var r = Run()
        r.feed.start(defaultInput: .bluetooth, hasBuiltin: hasBuiltin)
        if warm { r.feed.setWarmRoute() }
        let first = min(builtin?.from ?? Int.max, headset.from, boundary)
        var startedBuiltin = false, startedHeadset = false
        var n0 = first
        while n0 < end, r.failure == nil {
            if n0 == boundary { r.delivered += r.feed.recordingStarted(at: time(boundary)) }
            let arrival = time(n0 + chunk)
            func take(_ out: CaptureFeed.Output) {
                r.delivered += out.frames
                if let event = out.event { r.events.append(event) }
                if out.restartHeadset { r.restartRequests += 1 }
                if out.fallbackRefused { r.fallbackRefused += 1 }
                r.notes += out.notes
            }
            if hasBuiltin, let builtin, n0 >= builtin.from {
                if !startedBuiltin { r.feed.sourceStarted(.builtin, at: time(n0)); startedBuiltin = true }
                take(r.feed.accept(builtin.frames(n0), source: .builtin, at: time(n0), arrivedAt: arrival))
            }
            if n0 >= headset.from {
                if !startedHeadset { r.feed.sourceStarted(.headset, at: time(n0)); startedHeadset = true }
                take(r.feed.accept(headset.frames(n0), source: .headset, at: time(n0), arrivedAt: arrival))
            }
            n0 += chunk
            if n0 > boundary, (n0 - boundary) % 2_400 == 0 {
                let tick = r.feed.tick(at: time(n0))
                r.delivered += tick.frames
                r.notes += tick.notes
                if let failure = tick.failure { r.failure = failure }
            }
        }
        return r
    }

    // MARK: cold-link first-word loss (pre-roll)

    /// POSITIVE control: the link is already up (warm HFP) — the same assertion the cold fixture fails
    /// is passable: every frame of the first word reaches the dictation.
    @Test func warmLinkDeliversTheFirstWord() {
        let r = Self.run(hasBuiltin: false, warm: true, builtin: nil,
                         headset: Source(from: Self.boundary - 7_200), end: Self.boundary + 24_000)
        let delivered = r.wordDelivered == Self.wordFrames
        print("BT1 CONTROL first_word_delivered=\(delivered ? 1 : 0) frames=\(r.wordDelivered)")
        #expect(delivered)
        #expect(r.feed.bridge.firstKeptMs == 0)                  // the pre-roll ring held audio at the tap
    }

    /// Cold Bluetooth link with NO built-in (lid closed / desktop with a headset): the headset's first
    /// buffer arrives 600 ms after the tap; the word was spoken before any device delivered — no PCM
    /// exists to keep. Documents today's behaviour (the pill shows WARMING until the first buffer).
    @Test func coldLinkWithoutABuiltinLosesTheFirstWord() {
        let r = Self.run(hasBuiltin: false, builtin: nil,
                         headset: Source(from: Self.boundary + 14_400), end: Self.boundary + 36_000)
        let firstKept = r.feed.bridge.firstKeptMs ?? -1
        print("BT1 NOT DONE cold_link_first_word builtin=absent first_word_delivered=\(r.wordDelivered == Self.wordFrames ? 1 : 0)"
              + " frames=\(r.wordDelivered) first_kept_ms=\(firstKept)"
              + " (needs a warm-link policy: HFP input kept open or started before the first tap — no PCM exists to recover offline)")
        #expect(r.wordDelivered == 0)                            // current behaviour, documented
        #expect(firstKept == 650)                                // the headset's first buffer arrives at +600..650 ms
        #expect(r.feed.bridge.reason == "no_builtin")
    }

    /// Cold Bluetooth link WITH the built-in bridge (today's mitigation, v1.7+): the built-in, started at
    /// the first ⌥ tap, carries the first word (distant) until the headset's link is up.
    @Test func coldLinkWithTheBuiltinBridgeKeepsTheFirstWord() {
        let r = Self.run(hasBuiltin: true, builtin: Source(from: Self.boundary - 6_000, gain: Self.distant),
                         headset: Source(from: Self.boundary + 14_400), end: Self.boundary + 36_000)
        let delivered = r.wordDelivered == Self.wordFrames
        print("BT1 GREEN cold_link_first_word bridge=builtin first_word_delivered=\(delivered ? 1 : 0) frames=\(r.wordDelivered) (existing)")
        #expect(delivered)
        #expect(r.feed.bridge.state == .switched)                // the headset took over once its link carried
        #expect(r.delivered.count == Int(Double(CaptureRing.preRoll) * Self.rate) + 36_000)   // no gap, no duplicate
    }

    // MARK: headset digital silence with no built-in device (ASTRA §K)

    /// No built-in device in the set: no fallback is attempted against a missing device, the bridge
    /// names it (`reason=no_builtin`), the one headset restart is requested, and when the link comes
    /// back the headset carries on — every frame it delivered is in the dictation.
    @Test func noBuiltinHeadsetSilenceRecoversWithoutAFallback() {
        let silenceEnd = Self.boundary + 38_400                  // 1.6 s of exact zeros, then signal
        let r = Self.run(hasBuiltin: false, builtin: nil,
                         headset: Source(from: Self.boundary - 7_200, zerosUntil: silenceEnd),
                         end: Self.boundary + 62_400)
        let expected = Int(Double(CaptureRing.preRoll) * Self.rate) + 62_400
        let lost = expected - r.delivered.count
        let outcome = r.failure.map { "fail_\($0.reason.rawValue)" } ?? (r.feed.carrying == .headset ? "headset_carries" : "other")
        print("BT1 CONTROL no_builtin fallback_attempted=\(r.events.contains(.fallback) ? 1 : 0) outcome=\(outcome)"
              + " zeros_ms=1600 restart_requested=\(r.restartRequests) lost=\(lost) stage=bridge_src=none_reason=\(r.feed.bridge.reason ?? "-")")
        #expect(r.events.isEmpty)
        #expect(r.feed.bridge.reason == "no_builtin" && r.feed.bridge.bridgeSource == "none")
        #expect(r.restartRequests == 1)
        #expect(r.failure == nil && outcome == "headset_carries")
        #expect(lost == 0)
        #expect(r.notes.contains { $0.hasPrefix("health=warn reason=") })   // the silence is shown, not hidden
    }

    /// The same device set, the link never comes back: the dictation ends `mic_dead` at the absolute
    /// deadline with what was kept (all digital zeros — no speech existed to lose); still no fallback.
    @Test func noBuiltinPersistentSilenceEndsMicDeadWithoutAFallback() {
        let r = Self.run(hasBuiltin: false, builtin: nil,
                         headset: Source(from: Self.boundary - 7_200, allZeros: true), end: Self.boundary + 72_000)
        let failure = r.failure
        print("BT1 CONTROL no_builtin fallback_attempted=\(r.events.contains(.fallback) ? 1 : 0)"
              + " outcome=\(failure.map { $0.reason.rawValue } ?? "none") health=\(failure?.health?.rawValue ?? "-")"
              + " kept_ms=\(failure?.keptMs ?? -1)")
        #expect(r.events.isEmpty)
        #expect(failure?.reason == .micDead && failure?.health == .noInput)   // nothing useful ever arrived
        #expect(failure?.durationSeconds == CaptureHealth.failAfter)
        #expect((failure?.framesKept ?? 0) > 0)
    }

    /// Lid closed on a MacBook: the built-in device still exists but its hardware disconnect delivers
    /// exact zeros. With the headset also digitally silent, the bridge refuses the fallback onto a
    /// built-in that is not fresh (v1.8) — no switch to a dead mic — and the health clock decides.
    @Test func lidClosedBuiltinZerosIsNeverAFallbackTarget() {
        let r = Self.run(hasBuiltin: true, builtin: Source(from: Self.boundary - 6_000, allZeros: true),
                         headset: Source(from: Self.boundary - 6_000, allZeros: true), end: Self.boundary + 72_000)
        let failure = r.failure
        print("BT1 CONTROL lid_closed builtin=zeros fallback_taken=\(r.events.contains(.fallback) ? 1 : 0)"
              + " fallback_refused=\(r.fallbackRefused) outcome=\(failure.map { $0.reason.rawValue } ?? "none")")
        #expect(!r.events.contains(.fallback))
        #expect(r.fallbackRefused == 1)
        #expect(failure?.reason == .micDead)
    }
}
