import Foundation
import DictateCore

/// Replaces the microphone with a 24 kHz mono 16-bit WAV for unattended end-to-end runs:
/// 100 ms chunks paced in real time, then silence until stop(). Timeline: `bridge_src=inject`.
/// Every scenario runs the production CaptureFeed (arbitration, health clock, evidence) on a
/// media clock of 0.1 s per chunk, whatever the pace; levels come only from kept frames.
///
/// Scenarios (`DICTATE_INJECT_SCENARIO=`):
/// - `plain`: the WAV is the only (non-Bluetooth) input.
/// - `headset_zeros` (v1.7): the WAV is the built-in and a Bluetooth headset delivers only
///   digital zeros (a dropped eSCO link).
/// - `builtin_dies` (v1.8): as `headset_zeros`, but the built-in stops delivering after 0.5 s
///   (10-12 21:33). The health clock must end the dictation with `mic_dead`.
/// - `builtin_drifts` (v1.8): as `builtin_dies`, but the built-in's device read-back reports
///   another device (the aggregate) at 0.5 s and the unit is stopped.
/// - `sco_torn_down_250ms` (v1.9): the 10-13 01:53:08 race, timed from R1 (ms after the headset
///   start): AVAudioEngine auto-stops at +11, SCO connects at +200, our configuration
///   notification arrives at +242, a retap reaches IO 134 ms after it is begun, and coreaudiod
///   disables the idle SCO route at +450 unless IO is back by then. The re-attach is admitted by
///   the production `BluetoothRecoveryEpisode`; in time → the headset (the WAV) carries,
///   too late → it delivers only zeros. `legacyRecoveryTiming` = v1.8's debounced admission.
///   v1.10 (L1): the scenario also counts the engine operations (`stats.ioOps`) through the
///   production `HeadsetIOGuard`. `ioPolicy: .v19` is the RED twin: v1.9's re-attach ran
///   `TapFormatPlan` on the auto-stopped engine, whose hardware (16 kHz HFP) and client
///   (44.1 kHz) formats disagree, so it rebuilt — a teardown stop while the SCO link forms, which
///   drops eSCO creation (07:08:26 `Dropping eSCO creation`): the headset then delivers zeros.
///   `.v110` re-attaches once, converts in the tap and holds every other operation for
///   `HeadsetIOGuard.handsOff`. Restart requests go through the production episode in both.
/// - `headset_takeover` (v1.11 L4): R4 10-13 07:07:09 (41f98dbd). The WAV is the built-in; the
///   Bluetooth headset delivers zeros, then the WAV from `takeoverAt` — the headset takes over at
///   ~1.1 s (R4: `bridge_ms=1106 bridge_src=builtin`) and carries to the end. The restart the bridge
///   requests at 0.7 s of zeros is coalesced into the running recovery and never runs (R4 still
///   reported `headset_restart=1 result=still_silent`).
///
/// v1.13 two-stream scenarios (`Arm` sets the headset client's delivery size; the built-in AUHAL
/// delivers 10 ms buffers; both are interleaved in arrival order inside each 100 ms media tick):
/// - `pause_zeros` (L1 a): the headset = the WAV with `pauseLength` of exact zeros inserted at
///   `pauseAt`; the built-in = its room floor only (never exact zeros).
/// - `headset_drops` (L1 b): the headset = the WAV until `dropAt`, then exact zeros (a dead link);
///   the built-in = the WAV heard from a distance (`distantGain`) over its floor.
/// - `warm_hfp` (L2): the engine arm starting on a headset already on HFP (E4/W2, 10-13 15:24). The
///   device has usable frames from `WarmModel.framesFrom`; the engine's own start draws a configuration
///   notification at `WarmModel.notifyAt` while it runs, after which its tap delivers digital zeros until
///   a re-attach (retap) brings IO back `WarmModel.retapLatency` later; a restart (teardown, the 300 ms
///   idle wait, a fresh start) draws a stopping notification `WarmModel.restartStopsAfter` later and no
///   frames. The production `HeadsetIOGuard`, `BluetoothRecoveryEpisode` and `CaptureFeed` decide every
///   step, as the recorder does. `warmRoute` = what the recorder sampled (`route.hfpAlready()`).
/// - `splice_lag` (L3): both sources hear the WAV, but the headset's content trails its timestamps by
///   `headsetLag` (its voice link and codec delay, which a HAL timestamp does not carry; negative: it
///   leads); the built-in hears it distant. `spliceDropAt` (optional) drops the headset to exact zeros
///   there (a switchback splice).
/// - `live_pause` (L1 c): the 10-13 A/B as modeled — the WAV with the inserted pause, through the
///   Sony's mic gate (`gatePeak` per 20 ms → exact zeros) on the headset, distant on the built-in.
/// - `builtin_start_slow` (v1.27 B1): 2026-11-03 03:11:39 (cc891096), the first dictation after a pause.
///   The built-in AUHAL's `start(epoch:)` blocks `slowBuiltinStartReturnsAt` (its device read-back is
///   unreadable until then: `currentDeviceID == nil`), then it hears the WAV; the Bluetooth headset's start
///   is in flight until `slowHeadsetStartReturnsAt`, then it hears the WAV and takes over. The model runs
///   the recorder's per-tick device check (`BuiltinCapture.deviceCheck()` on an injected unit) and its
///   handling, then the production health clock.
/// - `transient_hfp` (v1.28 B1): 2026-11-03 f243a0c8 (`bt_start=hfp warm_ms=494`), a dictation started 100 ms
///   after the previous one released (`releaseGap`), on an HFP link that is collapsing back to A2DP. The engine
///   arm's tap delivers digital zeros from `TransientModel.zerosFrom`; the engine stops (no notification) at
///   `TransientModel.stopsAt` — the health clock sees it stopped; a re-attach (retap) brings IO back, still zeros
///   (the link is gone), and the link's flip draws a running configuration notification at
///   `TransientModel.collapseNotifyAt`. A restart re-requests HFP: its fresh engine starts
///   `TransientModel.restartTakes` after it begins, delivers nothing and is stopped by a notification
///   `TransientModel.restartStopsAfter` later. A re-attach after that brings IO with real signal (the WAV) from
///   `TransientModel.signalFrom`. The production guard, episode and feed decide every step, as the recorder does.
public final class WAVInjectedRecorder: EngineRecorder {
    /// Which re-attach the `sco_torn_down_250ms` IO model runs.
    public enum IOPolicy: Sendable { case v19, v110 }
    public enum Scenario: String, Sendable {
        case plain, headsetZeros = "headset_zeros", builtinDies = "builtin_dies", builtinDrifts = "builtin_drifts"
        case scoTornDown250ms = "sco_torn_down_250ms"
        case headsetTakeover = "headset_takeover"
        case pauseZeros = "pause_zeros", headsetDrops = "headset_drops", livePause = "live_pause"
        case warmHFP = "warm_hfp", spliceLag = "splice_lag"
        case builtinStartSlow = "builtin_start_slow"
        case transientHFP = "transient_hfp"
        var hasHeadset: Bool { self != .plain }
        /// v1.13: the headset and the built-in each play their own track.
        public var usesTracks: Bool {
            self == .pauseZeros || self == .headsetDrops || self == .livePause || self == .warmHFP || self == .spliceLag
                || self == .transientHFP
        }
        /// The warm/transient HFP IO model (the recorder's policy on the production guard and episode).
        var hfpModel: Bool { self == .warmHFP || self == .transientHFP }
    }
    /// v1.13: the headset client modeled — only the size of the headset's deliveries differs (10-13 A/B
    /// session lines: engine `io_callbacks=…headset:149 frames=…headset:357552` = 2400 frames per
    /// callback; auhal 812 / 389712 = 480).
    public enum Arm: String, Sendable, CaseIterable {
        case engine, auhal
        public var headsetBufferFrames: Int { self == .engine ? 2_400 : 480 }
    }
    /// The built-in AUHAL's deliveries (10-13: 1562 callbacks / 399864 frames ≈ 256), 10 ms here.
    public static let builtinBufferFrames = 240
    /// The distant built-in hears the speaker ~18 dB below the headset (A1 `rms_dbfs=builtin:-46.0,headset:-27.0`).
    public static let distantGain: Float = 0.126
    /// The built-in's room floor: deterministic noise within ±0.001 (−60 dBFS), never an exact zero.
    public static let noiseFloor: Float = 0.001
    /// The Sony's mic gate as modeled: a 20 ms window whose peak is below this arrives as exact zeros.
    public static let gatePeak: Float = 0.02
    public var arm: Arm = .engine
    /// `pause_zeros` / `live_pause`: where the inserted pause starts (s into the WAV) and its length.
    public var pauseAt: TimeInterval = 1.0
    public var pauseLength: TimeInterval = 2.0
    /// `headset_drops`: media time after the boundary from which the headset delivers only zeros.
    public var dropAt: TimeInterval = 1.0
    /// `splice_lag`: seconds the headset's content trails its timestamps (negative: leads).
    public var headsetLag: TimeInterval = 0.06
    /// `splice_lag`: media time from which the headset delivers only zeros (nil: never).
    public var spliceDropAt: TimeInterval?
    /// `warm_hfp`: the recorder found the headset already on HFP (false: the cold flag on the same IO).
    public var warmRoute = true
    /// `warm_hfp` IO model, from the E4 (f9fc0895) / W2 (c3e8e1f9) lines of 10-13 15:24.
    public enum WarmModel {
        /// The spec's warm fixture: usable headset frames from t0 + 50 ms.
        public static let framesFrom: TimeInterval = 0.05
        /// `bt_recovery=hands_off path=configuration engine_running=1` 116 ms after the start (W2; E4 113).
        public static let notifyAt: TimeInterval = 0.116
        /// Re-attach → IO: W2 `reattach path=obligation` 50.381 → `bridge_switch=headset` 50.621 = 240 ms,
        /// less the 150 ms takeover.
        public static let retapLatency: TimeInterval = 0.09
        /// `headset_restart=1 … waited_ms=300` (the idle wait before the fresh start).
        public static let restartIdleWait: TimeInterval = 0.3
        /// The restarted engine is stopped by a notification 128 ms later (W2 49.464 → 49.592
        /// `obligation path=configuration engine_running=0`) and delivers no frames (`result=no_frames`).
        public static let restartStopsAfter: TimeInterval = 0.128
    }
    /// `transient_hfp` IO model, from f243a0c8 (standalone 1.25, 2026-11-03; v1.26 report lines 18–21).
    public enum TransientModel {
        /// The previous dictation (58ca434f, 170 ms) released 100 ms before this start.
        public static let releasedBefore: TimeInterval = 0.1
        /// The engine's first buffers (digital zeros on the collapsing link): `builtin_fallback` at +1906 = first
        /// headset buffer + `CaptureBridge.fallbackAfter`.
        public static let zerosFrom: TimeInterval = 0.4
        /// The engine stops without a notification; the health clock sees it (`reattach path=obligation
        /// reason=engine_stopped` +988).
        public static let stopsAt: TimeInterval = 0.95
        /// The link's flip back to A2DP (`bt_after3s=a2dp` ~+1.0) reaches the running engine while its re-attach is
        /// in flight, before that re-attach's IO (f243a0c8 shows ONE re-attach, then `escalate` right after its verdict).
        public static let collapseNotifyAt: TimeInterval = 1.05
        /// `queued path=restart wait_ms=484` → `headset_restart=1 path=restart idle=1 waited_ms=300` +3402: the
        /// restart's teardown, idle wait and fresh start took ≈ 0.9 s.
        public static let restartTakes: TimeInterval = 0.9
        /// `obligation path=configuration engine_running=0` +3654: the fresh engine stopped 252 ms after its start.
        public static let restartStopsAfter: TimeInterval = 0.25
        /// The restart re-requested HFP; a re-attached client hears the speaker from here.
        public static let signalFrom: TimeInterval = 4.5
    }
    /// `transient_hfp`: seconds between the previous capture's release and this start (nil: none this launch).
    public var releaseGap: TimeInterval?
    /// `transient_hfp`: the HFP link is usable (false while it collapses; the restart re-requests it).
    private var transientLinkUp = false
    /// The model's restart is between its teardown and its fresh start (the recorder's `restarting`).
    private var warmRestarting = false
    private var warmRestartBegun = false
    /// Test harness (v1.28 C MISSING-EVENT): every re-attach after the restart began is declined.
    public var reattachesWithheldAfterRestart = false
    private enum WarmEvent { case notify(running: Bool), ioBack, restartStart, restart, settle(CaptureEpoch), silentStop }
    private var warmEvents: [(at: TimeInterval, event: WarmEvent)] = []
    private var warmRunning = true
    private var warmTapOK = true
    /// The restarted engine runs but delivers nothing (W2 `bt_recovery=settled path=restart result=no_frames`).
    private var warmNoFrames = false
    private var warmIO = HeadsetIOGuard(bluetooth: true)
    private var warmEpisode = BluetoothRecoveryEpisode(bluetooth: true)
    private var warmVerify: (token: CaptureEpoch, since: TimeInterval, firstFrame: TimeInterval?, signal: SustainedSignal, firstSignal: TimeInterval?)?
    /// Every note with its media ms after the boundary (tests read when a switch happened).
    public private(set) var timedNotes: [(ms: Int, line: String)] = []
    /// Media ms since the recording boundary (tests wait on the media clock, not on wall time).
    public var mediaMs: Int { lock.withLock { Int(((mediaTime - boundary) * 1000).rounded()) } }
    private var headsetTrack: [Float] = []
    private var builtinTrack: [Float] = []
    private var trackCursor = 0
    /// `builtin_start_slow`: media time after the boundary at which the built-in's start returns
    /// (cc891096: `builtin_backend=auhal device=81 bridge_device_check=ok` at +1.577).
    public static let slowBuiltinStartReturnsAt: TimeInterval = 1.5
    /// `builtin_start_slow`: the headset's start returns and its frames flow (cc891096 `engine_start_ms=1932`; takeover 2.2–2.5 s).
    public static let slowHeadsetStartReturnsAt: TimeInterval = 2.2
    /// `builtin_start_slow`: the injected built-in unit whose read-back the model checks every tick.
    private let slowUnit = InjectedBuiltinUnit()
    private var slowDriftNoted = false
    private var slowRebuilt = false
    private var slowUnreadable = false
    private var slowStartAt = WAVInjectedRecorder.slowBuiltinStartReturnsAt
    /// Built-in frames stop after this much media time in the dying scenarios.
    public static let builtinLifetime: TimeInterval = 0.5
    /// `sco_torn_down_250ms` timing (s after the headset start; R1 01:53:08.300 + …).
    public static let scoNotifyAt: TimeInterval = 0.242
    public static let scoRetapLatency: TimeInterval = 0.134
    public static let scoRouteDisabledAt: TimeInterval = 0.45
    /// `headset_takeover`: media time after the boundary from which the headset delivers the WAV.
    public static let takeoverAt: TimeInterval = 0.85
    /// v1.8's admission (debounced even when the engine auto-stopped): the RED twin.
    public let legacyRecoveryTiming: Bool
    public let ioPolicy: IOPolicy
    /// When the re-attached headset IO runs (nil: not computed for this scenario).
    public private(set) var scoIOAt: TimeInterval?
    public let url: URL
    public let pace: Double
    public let scenario: Scenario
    /// Test harness (v1.10): media time after the boundary at which the media clock stops (no more
    /// frames, health ticks or notes). A starved test thread can no longer let the clock run past
    /// the WAV into zeros (10-13: `health=warn reason=zeros` at media 7.4–13.1 s of a 7 s WAV).
    public var mediaLimit: TimeInterval?
    /// Diagnostics sink (the engine's notes by default); tests keep their notes local.
    public var note: (String) -> Void = { AppController.note($0) }

    public var onLevel: ((Double) -> Void)?
    public var onPCMChunk: (([Int16]) -> Void)?
    public var onFirstBuffer: (() -> Void)?
    public var onCaptureFailure: ((CaptureFailure) -> Void)?

    public private(set) var stats: AudioRecorder.CaptureStats
    /// The evidence's RMS series at the last stop (counts-only levels; tests replay it).
    public private(set) var levelEnvelope: [Float] = []
    public var bridgeHasAudio: Bool { false }

    public var isRunning: Bool { lock.withLock { timer != nil || manualRunning } }
    public var isAllocated: Bool { lock.withLock { timer != nil || manualRunning } }
    /// Test harness (v1.12 L4): no timer — the test advances the media clock with `step()`, so a
    /// starved runner can never cut a scenario short (the suite's wall-clock flake).
    public var manualPacing = false
    private var manualRunning = false

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dictate.capture.injected")
    private var timer: DispatchSourceTimer?
    private var wavSamples: [Int16] = []
    private var sampleCursor: Int = 0
    private var buffer: [Float] = []
    private var firstBufferFired: Bool = false
    private var meter = WisprLevel()
    private var feed = CaptureFeed()
    private var pendingPCM: [Int16] = []
    private let delivery = OrderedDelivery<[Int16]>()
    /// Media clock of the feed: 0.1 s per chunk whatever the pace.
    private var mediaTime: TimeInterval = 0
    private var boundary: TimeInterval = 0
    private var builtinStopped = false
    private var failed = false

    public init(url: URL, pace: Double = 1.0, scenario: Scenario = .plain, legacyRecoveryTiming: Bool = false,
                ioPolicy: IOPolicy = .v110) {
        self.legacyRecoveryTiming = legacyRecoveryTiming
        self.ioPolicy = ioPolicy
        self.url = url
        self.pace = max(0.0001, pace)
        self.scenario = scenario
        var s = AudioRecorder.CaptureStats()
        s.device = "injected:\(url.lastPathComponent)"
        s.startFormat = "24000Hz/1ch"
        s.bridgeSource = "inject"
        self.stats = s
        if scenario == .transientHFP { releaseGap = TransientModel.releasedBefore }
    }

    /// The scenario named by `DICTATE_INJECT_SCENARIO`; plain when unset or unknown.
    public static func scenario(environment: [String: String]) -> Scenario {
        environment["DICTATE_INJECT_SCENARIO"].flatMap(Scenario.init(rawValue:)) ?? .plain
    }

    public static func parseWAV(at url: URL) throws -> [Int16] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AudioRecorder.RecorderError.noInput
        }
        guard data.count >= 12,
              data.starts(with: "RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8) else {
            throw AudioRecorder.RecorderError.noInput
        }

        var foundFmt = false
        var pcmSamples: [Int16] = []
        var offset = 12

        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4]) |
                       (Int(data[offset + 5]) << 8) |
                       (Int(data[offset + 6]) << 16) |
                       (Int(data[offset + 7]) << 24)
            guard size >= 0 else { throw AudioRecorder.RecorderError.noInput }
            let chunkStart = offset + 8
            let chunkEnd = min(data.count, chunkStart + size)

            if id == "fmt " {
                guard size >= 16, chunkEnd - chunkStart >= 16 else {
                    throw AudioRecorder.RecorderError.noInput
                }
                let format = UInt16(data[chunkStart]) | (UInt16(data[chunkStart + 1]) << 8)
                let channels = UInt16(data[chunkStart + 2]) | (UInt16(data[chunkStart + 3]) << 8)
                let rate = UInt32(data[chunkStart + 4]) |
                           (UInt32(data[chunkStart + 5]) << 8) |
                           (UInt32(data[chunkStart + 6]) << 16) |
                           (UInt32(data[chunkStart + 7]) << 24)
                let bits = UInt16(data[chunkStart + 14]) | (UInt16(data[chunkStart + 15]) << 8)
                // WAVE_FORMAT_EXTENSIBLE (0xFFFE, what afconvert writes) counts as PCM when its
                // subformat GUID is KSDATAFORMAT_SUBTYPE_PCM (00000001-0000-0010-8000-00aa00389b71).
                let pcmGUID: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71]
                let isPCM = format == 1 || (format == 0xFFFE && size >= 40 && chunkEnd - chunkStart >= 40
                    && Array(data[(chunkStart + 24)..<(chunkStart + 40)]) == pcmGUID)
                guard isPCM, channels == 1, rate == 24_000, bits == 16 else {
                    throw AudioRecorder.RecorderError.noInput
                }
                foundFmt = true
            } else if id == "data" {
                pcmSamples.reserveCapacity((chunkEnd - chunkStart) / 2)
                var i = chunkStart
                while i + 1 < chunkEnd {
                    pcmSamples.append(Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8)))
                    i += 2
                }
            }
            offset += 8 + size + (size & 1)
        }

        guard foundFmt else {
            throw AudioRecorder.RecorderError.noInput
        }
        return pcmSamples
    }

    /// v1.13: the two tracks a two-stream scenario plays (headset, built-in), from the WAV's samples.
    public static func tracks(_ scenario: Scenario, wav: [Float], pauseAt: TimeInterval, pauseLength: TimeInterval,
                              dropAt: TimeInterval, headsetLag: TimeInterval = 0,
                              spliceDropAt: TimeInterval? = nil) -> (headset: [Float], builtin: [Float]) {
        let rate = AudioRecorder.sampleRate
        func inserted(_ x: [Float]) -> [Float] {
            let at = min(x.count, max(0, Int((pauseAt * rate).rounded())))
            return Array(x[..<at]) + [Float](repeating: 0, count: max(0, Int((pauseLength * rate).rounded()))) + Array(x[at...])
        }
        func distant(_ x: [Float]) -> [Float] { x.enumerated().map { $0.element * distantGain + floorSample($0.offset) } }
        func gated(_ x: [Float]) -> [Float] {
            var out = x
            for start in stride(from: 0, to: x.count, by: 480) {
                let end = min(x.count, start + 480)
                if !x[start..<end].contains(where: { abs($0) >= gatePeak }) {
                    for i in start..<end { out[i] = 0 }
                }
            }
            return out
        }
        switch scenario {
        case .pauseZeros:
            let headset = inserted(wav)
            return (headset, (0..<headset.count).map(floorSample))
        case .headsetDrops:
            let drop = min(wav.count, max(0, Int((dropAt * rate).rounded())))
            return (Array(wav[..<drop]) + [Float](repeating: 0, count: wav.count - drop), distant(wav))
        case .livePause:
            let speech = inserted(wav)
            return (gated(speech), distant(speech))
        case .warmHFP, .transientHFP:
            return (wav, distant(wav))
        case .spliceLag:
            let lag = Int((headsetLag * rate).rounded())
            var headset = (0..<wav.count).map { i -> Float in
                let j = i - lag
                return j >= 0 && j < wav.count ? wav[j] : 0
            }
            if let drop = spliceDropAt {
                for i in min(headset.count, max(0, Int((drop * rate).rounded())))..<headset.count { headset[i] = 0 }
            }
            return (headset, distant(wav))
        default:
            return ([], [])
        }
    }

    /// The built-in's room floor at sample `index`: deterministic, within ±`noiseFloor`, never 0.
    public static func floorSample(_ index: Int) -> Float {
        var x = UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 29; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 32
        let unit = Float(x % 2_001) / 1_000 - 1                       // −1 … 1 in steps of 0.001
        return (unit == 0 ? 0.5 : unit) * noiseFloor
    }

    public func start(device: MicChoice = .default) throws {
        // Parse before taking the lock: a throw must never leave it held (isRunning is read next).
        try start(parsed: Self.parseWAV(at: url))
    }

    private func start(parsed: [Int16]) throws {
        lock.lock()
        if timer != nil || manualRunning {
            lock.unlock()
            return
        }
        wavSamples = parsed
        sampleCursor = 0
        if scenario.usesTracks {
            (headsetTrack, builtinTrack) = Self.tracks(scenario, wav: parsed.map { Float($0) / 32768.0 }, pauseAt: pauseAt,
                                                       pauseLength: pauseLength, dropAt: dropAt, headsetLag: headsetLag,
                                                       spliceDropAt: spliceDropAt)
        }
        trackCursor = 0
        timedNotes = []
        firstBufferFired = false
        buffer.removeAll()
        meter.clearBatch()
        pendingPCM.removeAll()
        mediaTime = 1_000
        feed.start(defaultInput: scenario.hasHeadset ? .bluetooth : .other, hasBuiltin: scenario.hasHeadset)
        // v1.27 (B1): the built-in joins the health clock when its start returns (the recorder's `startBuiltin`).
        if scenario.hasHeadset, scenario != .builtinStartSlow { feed.sourceStarted(.builtin, at: mediaTime) }
        feed.sourceStarted(.headset, at: mediaTime)
        if scenario == .builtinStartSlow { feed.headsetStart(inFlight: true) }
        boundaryAt(mediaTime)
        if manualPacing {
            manualRunning = true
            lock.unlock()
            return
        }

        // WAV pacing is a media clock: background timer coalescing must not stretch injected playback.
        let timerSource = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let intervalSeconds = 0.1 * pace
        let intervalNs = max(1_000, Int((intervalSeconds * 1_000_000_000).rounded()))
        timerSource.schedule(deadline: .now() + .nanoseconds(intervalNs), repeating: .nanoseconds(intervalNs))
        timerSource.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timerSource
        timerSource.resume()
        lock.unlock()
    }

    /// `manualPacing`: one 100 ms media tick on the caller's thread (no-op when not running).
    public func step() { queue.sync { tick() } }

    /// Caller holds `lock`.
    private func boundaryAt(_ time: TimeInterval) {
        _ = feed.recordingStarted(at: time, preRoll: 0)
        boundary = time
        builtinStopped = false
        failed = false
        scoIOAt = nil
        scoNotes = []
        ioGuard = HeadsetIOGuard(bluetooth: scenario.hasHeadset)
        ioPending = []
        ioSettleAt = nil
        ioRestartAt = nil
        scoKept = false
        slowDriftNoted = false
        slowRebuilt = false
        slowUnreadable = false
        slowStartAt = Self.slowBuiltinStartReturnsAt
        slowUnit.reset()
        if scenario.hfpModel {
            warmRunning = true
            warmTapOK = true
            warmNoFrames = false
            warmRestarting = false
            warmRestartBegun = false
            transientLinkUp = false
            // The 3a48d95 recorder: HFP at the start is a warm route (`route.hfpAlready()`), however long it has been up.
            warmIO = HeadsetIOGuard(bluetooth: true, warmRoute: warmRoute)
            warmEpisode = BluetoothRecoveryEpisode(bluetooth: true)
            warmVerify = nil
            if scenario == .transientHFP {
                warmEvents = [(time + TransientModel.stopsAt, .silentStop),
                              (time + TransientModel.collapseNotifyAt, .notify(running: true))]
            } else {
                warmEvents = arm == .engine ? [(time + WarmModel.notifyAt, .notify(running: true))] : []
            }
            if warmRoute { feed.setWarmRoute() }
        }
        if scenario == .scoTornDown250ms {
            let notify = Self.scoNotifyAt
            ioEpisode = BluetoothRecoveryEpisode(bluetooth: true)
            ioEpisode.formatChanged(at: notify)
            ioPending = [(0, .start)]
            var policyNotes: [String] = []
            if !legacyRecoveryTiming, ioPolicy == .v110,
               case .leaveRunning = ioGuard.configurationChanged(at: notify, engineRunning: false) {
                policyNotes.append("bt_recovery=hands_off path=configuration engine_running=1")   // never: it auto-stopped
            }
            let admission = ioEpisode.request(.configuration, at: notify, engineStopped: !legacyRecoveryTiming)
            var wait: TimeInterval = 0
            switch admission {
            case .now: break
            case .after(let delay): wait = delay
            case .coalesced, .exhausted: wait = .infinity
            }
            let attachAt = notify + wait
            // v1.10 asks the production guard whether the re-attach converts in the tap.
            let rebuildsOnReattach = !legacyRecoveryTiming && (ioPolicy == .v19 || !ioGuard.convertsInTap)
            if wait.isFinite {
                _ = ioEpisode.begin(at: attachAt, force: true)
                ioPending.append((attachAt, .retap))
                if rebuildsOnReattach {
                    // TapFormatPlan on the auto-stopped engine: mismatch → rebuild (teardown stop).
                    ioPending += [(attachAt, .rebuild), (attachAt, .stop)]
                }
                ioPending.append((attachAt, .start))
                ioSettleAt = attachAt + BluetoothRecoveryEpisode.successWithin
            }
            scoIOAt = attachAt + Self.scoRetapLatency
            scoKept = !rebuildsOnReattach && scoIOAt! < Self.scoRouteDisabledAt
            scoNotes = (ioEpisode.immediateAttempts > 0
                ? ["bt_recovery=immediate path=configuration engine_running=0 after_ms=0"]
                : ["bt_recovery=queued path=configuration wait_ms=\(Int((wait * 1000).rounded()))"]) + policyNotes
        }
    }
    private var scoNotes: [String] = []
    // v1.10 (L1) IO model of `sco_torn_down_250ms` (state under `lock`; offsets from the boundary).
    private var ioGuard = HeadsetIOGuard(bluetooth: false)
    private var ioEpisode = BluetoothRecoveryEpisode(bluetooth: true)
    private var ioPending: [(at: TimeInterval, op: HeadsetIOGuard.Op)] = []
    private var ioSettleAt: TimeInterval?
    private var ioRestartAt: TimeInterval?
    private var scoKept = false

    /// Applies the IO model up to `offset`: due operations, the attempt's verdict, a due restart.
    /// Caller holds `lock`.
    private func advanceIO(to offset: TimeInterval) {
        guard scenario == .scoTornDown250ms else { return }
        if let settle = ioSettleAt, offset >= settle {
            ioSettleAt = nil
            ioEpisode.settled(scoKept ? .frames : .silentFrames)
        }
        if let restart = ioRestartAt, offset >= restart {
            ioRestartAt = nil
            runRestart(at: restart)
        }
        while let next = ioPending.first, next.at <= offset {
            ioGuard.record(next.op)
            ioGuard.finished(next.op, ok: true)             // the model's operations all return
            ioPending.removeFirst()
        }
    }

    /// The feed asked for the one headset restart (`AudioRecorder.requestHeadsetRestart`).
    /// Caller holds `lock`.
    private func requestRestart(at offset: TimeInterval) {
        guard scenario == .scoTornDown250ms else { return }
        var at = offset
        if !legacyRecoveryTiming, ioPolicy == .v110, !ioGuard.allows(at: offset) {
            ioGuard.deferred()
            at = offset + ioGuard.remaining(at: offset)
        }
        if at > offset { ioRestartAt = at } else { runRestart(at: at) }
    }

    /// Admitted like `restartHeadset`: teardown (stop) then a fresh engine (no rebuild count) and start.
    private func runRestart(at time: TimeInterval) {
        switch ioEpisode.request(.restart, at: time) {
        case .now:
            _ = ioEpisode.begin(at: time, force: true)
            ioPending += [(time, .stop), (time, .start)]
            ioPending.sort { $0.at < $1.at }
            ioSettleAt = time + BluetoothRecoveryEpisode.successWithin
        case .after(let wait):
            ioRestartAt = time + wait
        case .coalesced, .exhausted: break
        }
    }

    /// The headset's buffer for the chunk at `offset` s after the boundary (nil: its engine is stopped).
    private func headsetChunk(offset: TimeInterval, wav: [Float]) -> [Float]? {
        if scenario == .headsetTakeover { return offset + 1e-9 >= Self.takeoverAt ? wav : [Float](repeating: 0, count: wav.count) }
        guard scenario == .scoTornDown250ms, let io = scoIOAt else { return [Float](repeating: 0, count: wav.count) }
        guard offset + 0.1 > io else { return nil }
        // IO back before the teardown keeps the route: the headset hears the speaker.
        return scoKept ? wav : [Float](repeating: 0, count: wav.count)
    }

    // MARK: v1.13 (L2) warm_hfp IO model — the recorder's policy on the production guard/episode. Caller holds `lock`.

    /// Applies every model event due before `end`, in time order (an event may schedule more).
    private func warmAdvance(to end: TimeInterval) -> [String] {
        var notes: [String] = []
        while let next = warmEvents.enumerated().filter({ $0.element.at < end - 1e-9 }).min(by: { $0.element.at < $1.element.at }) {
            warmEvents.remove(at: next.offset)
            let at = next.element.at
            switch next.element.event {
            case .notify(let running):
                if !running { warmRunning = false }
                else if warmTapOK { warmTapOK = false }        // the running tap goes to digital zeros
                warmEpisode.formatChanged(at: at)
                let evidence = feed.headsetFormatChanged(at: at)
                pendingWarmFrames += evidence.frames
                notes += evidence.notes
                switch warmIO.configurationChanged(at: at, engineRunning: running) {
                case .leaveRunning: notes.append("bt_recovery=hands_off path=configuration engine_running=1")
                case .reattach: notes += warmReattach(at: at, notified: true)
                case .escalate: notes += warmRequestRestart(at: at)
                case .pending, .none, .exhausted, .episode:
                    notes.append("bt_recovery=obligation path=configuration engine_running=\(running ? 1 : 0) in_flight=1")
                }
            case .silentStop:
                warmRunning = false
            case .ioBack:
                warmRunning = true
                warmTapOK = true
                warmNoFrames = false
            case .restart:
                notes += warmRestart(at: at)
            case .restartStart:
                warmRestarting = false
                warmRunning = true
                warmNoFrames = true                            // no frames from the restarted engine …
                if scenario == .transientHFP { transientLinkUp = true }    // its idle wait re-requested HFP
                let stopsAfter = scenario == .transientHFP ? TransientModel.restartStopsAfter : WarmModel.restartStopsAfter
                warmEvents.append((at + stopsAfter, .notify(running: false)))   // … then it stops
            case .settle(let token):
                guard let check = warmVerify, check.token === token else { break }
                warmVerify = nil
                guard warmEpisode.isRunning else { break }
                let outcome = BluetoothRecoveryEpisode.verdict(since: check.since, firstFrame: check.firstFrame,
                                                               firstSignal: check.firstSignal)
                warmEpisode.settled(outcome)
                notes.append("bt_recovery=settled result=\(outcome.rawValue)")
            }
        }
        return notes
    }
    private var pendingWarmFrames: [Float] = []

    /// The engine's buffer for the window starting at `from`: digital zeros while the tap is broken,
    /// nothing at all while the engine is stopped, zeros before the device's first frames.
    private func warmHeadset(_ window: [Float], from: TimeInterval) -> ([Float], Bool) {
        if scenario == .transientHFP {
            // Nothing before the engine's first buffers or while it is stopped; zeros until the link is back,
            // a re-attached tap is running and the speaker is heard.
            guard from - boundary >= TransientModel.zerosFrom - 1e-9, warmRunning, !warmNoFrames else { return (window, false) }
            return (window.enumerated().map { index, sample in
                let t = from + Double(index) / AudioRecorder.sampleRate - boundary
                return transientLinkUp && warmTapOK && t >= TransientModel.signalFrom - 1e-9 ? sample : 0
            }, true)
        }
        guard arm == .engine else {
            return (window.enumerated().map { from + Double($0.offset) / AudioRecorder.sampleRate - boundary < WarmModel.framesFrom ? 0 : $0.element }, true)
        }
        guard warmRunning, !warmNoFrames else { return (window, false) }
        let notifyOffset = warmTapOK ? Int.max : 0
        return (window.enumerated().map { index, sample in
            let t = from + Double(index) / AudioRecorder.sampleRate - boundary
            return t < WarmModel.framesFrom || !warmTapOK || index >= notifyOffset ? 0 : sample
        }, true)
    }

    /// Headset frames reached the recorder: the guard and the verification see them; the bridge may ask
    /// for its one zero-run restart.
    private func warmHeadsetFrames(_ frames: [Float], arrived: TimeInterval, restart: Bool) -> [String] {
        let peak = frames.reduce(Float(0)) { max($0, abs($1)) }
        warmIO.headsetFrames(frames.count, peak: peak, at: arrived)
        if var check = warmVerify, arrived > check.since {
            if check.firstFrame == nil { check.firstFrame = arrived }
            if check.firstSignal == nil, let reached = check.signal.add(frames: frames.count, peak: peak, at: arrived) {
                check.firstSignal = reached
            }
            warmVerify = check
        }
        guard restart else { return [] }
        return warmRequestRestart(at: arrived)
    }

    /// The health clock's observation of the engine (the recorder's `ioGuard.observe`).
    private func warmObserve(at now: TimeInterval) -> [String] {
        guard scenario.hfpModel, arm == .engine, !warmRestarting else { return [] }
        switch warmIO.observe(at: now, engineRunning: warmRunning) {
        case .reattach: return warmReattach(at: now, notified: false)
        case .escalate: return ["bt_recovery=escalate path=obligation"] + warmRequestRestart(at: now)
        default: return []
        }
    }

    /// The obligation's one re-attach (a retap), admitted by the episode like the recorder's.
    private func warmReattach(at now: TimeInterval, notified: Bool) -> [String] {
        if reattachesWithheldAfterRestart, warmRestartBegun { warmIO.reattachDeclined(); return [] }
        guard warmEpisode.admitReattach(at: now) else {
            if warmEpisode.budgetSpent { warmIO.reattachUnavailable() } else { warmIO.reattachDeclined() }
            return notified ? ["bt_recovery=obligation path=configuration engine_running=\(warmRunning ? 1 : 0) in_flight=1"] : []
        }
        warmIO.record(.retap)
        warmIO.finished(.retap, ok: true)
        warmIO.reattachFinished(started: true, at: now)
        warmArmVerify(since: now)
        warmEvents.append((now + WarmModel.retapLatency, .ioBack))
        return [notified ? "bt_recovery=immediate path=configuration engine_running=\(warmRunning ? 1 : 0) after_ms=0"
                         : "bt_recovery=reattach path=obligation"]
    }

    private func warmArmVerify(since: TimeInterval) {
        let token = CaptureEpoch()
        warmVerify = (token, since, nil, SustainedSignal(), nil)
        warmEvents.append((since + BluetoothRecoveryEpisode.successWithin, .settle(token)))
    }

    /// `requestHeadsetRestart`: admitted by the episode, run when due.
    private func warmRequestRestart(at now: TimeInterval) -> [String] {
        switch warmEpisode.request(.restart, at: now) {
        case .now: warmEvents.append((now, .restart)); return []
        case .after(let wait): warmEvents.append((now + wait, .restart)); return ["bt_recovery=queued path=restart wait_ms=\(Int((wait * 1000).rounded()))"]
        case .coalesced: return []
        case .exhausted: return ["bt_recovery=exhausted path=restart"]
        }
    }

    /// `restartHeadset`: hands-off wait, the stable-format debounce, then teardown, idle wait, start.
    private func warmRestart(at now: TimeInterval) -> [String] {
        let held = warmIO.remaining(at: now)
        if held > 0 { warmIO.deferred(); warmEvents.append((now + held, .restart)); return [] }
        switch warmEpisode.beginIfStable(at: now) {
        case .notPending: return []
        case .wait(let more): warmEvents.append((now + more, .restart)); return []
        case .begun: break
        }
        warmIO.record(.stop); warmIO.finished(.stop, ok: true)
        warmRunning = false
        warmRestarting = true
        warmRestartBegun = true
        let start = now + (scenario == .transientHFP ? TransientModel.restartTakes : WarmModel.restartIdleWait)
        warmIO.record(.start); warmIO.finished(.start, ok: true)
        feed.headsetRestarted()
        warmArmVerify(since: start)
        warmEvents.append((start, .restartStart))
        return ["headset_restart=1 path=restart idle=1 waited_ms=\(Int((WarmModel.restartIdleWait * 1000).rounded())) started=1"]
    }

    /// Parses off the caller's actor (the controller calls this from the main actor).
    public func startAsync(device: MicChoice = .default) async throws {
        if isRunning { return }
        let url = self.url
        let parsed = try await Task.detached { try Self.parseWAV(at: url) }.value
        try start(parsed: parsed)
    }

    private func tick() {
        lock.lock()
        guard timer != nil || manualRunning, mediaLimit.map({ mediaTime - boundary < $0 - 1e-9 }) ?? true else {
            lock.unlock()
            return
        }

        var chunk = [Int16]()
        chunk.reserveCapacity(AudioRecorder.chunkSamples)
        if sampleCursor < wavSamples.count {
            let remaining = wavSamples.count - sampleCursor
            if remaining >= AudioRecorder.chunkSamples {
                chunk = Array(wavSamples[sampleCursor..<(sampleCursor + AudioRecorder.chunkSamples)])
                sampleCursor += AudioRecorder.chunkSamples
            } else {
                chunk = Array(wavSamples[sampleCursor..<wavSamples.count])
                sampleCursor = wavSamples.count
                chunk.append(contentsOf: repeatElement(0, count: AudioRecorder.chunkSamples - chunk.count))
            }
        } else {
            chunk = [Int16](repeating: 0, count: AudioRecorder.chunkSamples)
        }

        let wav = chunk.map { Float($0) / 32768.0 }
        var notes: [String] = []
        let time = mediaTime
        mediaTime += Double(chunk.count) / AudioRecorder.sampleRate
        var kept: [Float] = []
        var noteTimes: [Int] = []
        if scenario.usesTracks {
            // v1.13: each source plays its own track in its own buffer size, interleaved by arrival
            // (a buffer arrives when its last frame was captured; the built-in first on a tie).
            let n = wav.count
            let base = trackCursor
            trackCursor += n
            var headset = (0..<n).map { base + $0 < headsetTrack.count ? headsetTrack[base + $0] : 0 }
            var headsetDelivers = true
            if scenario.hfpModel {
                notes += warmAdvance(to: time + Double(n) / AudioRecorder.sampleRate)
                (headset, headsetDelivers) = warmHeadset(headset, from: time)
            }
            let builtinWindow = (0..<n).map { base + $0 < builtinTrack.count ? builtinTrack[base + $0] : Self.floorSample(base + $0) }
            var deliveries: [(start: Int, end: Int, source: CaptureBridge.Source)] = []
            for start in stride(from: 0, to: n, by: Self.builtinBufferFrames) {
                deliveries.append((start, min(n, start + Self.builtinBufferFrames), .builtin))
            }
            for start in stride(from: 0, to: n, by: arm.headsetBufferFrames) where headsetDelivers {
                deliveries.append((start, min(n, start + arm.headsetBufferFrames), .headset))
            }
            deliveries.sort { $0.end != $1.end ? $0.end < $1.end : ($0.source == .builtin && $1.source == .headset) }
            for delivery in deliveries {
                let frames = Array((delivery.source == .builtin ? builtinWindow : headset)[delivery.start..<delivery.end])
                let at = time + Double(delivery.start) / AudioRecorder.sampleRate
                let arrived = time + Double(delivery.end) / AudioRecorder.sampleRate
                let out = feed.accept(frames, source: delivery.source, at: at, arrivedAt: arrived)
                var lines: [String] = []
                if scenario.hfpModel, delivery.source == .headset {
                    lines += warmHeadsetFrames(frames, arrived: arrived, restart: out.restartHeadset)
                }
                if out.event == .fallback { lines.append("bridge_src=builtin_fallback reason=headset_digital_silence") }
                if out.event == .switchback { lines.append("bridge_switchback=1") }
                lines += out.notes
                notes += lines
                noteTimes += lines.map { _ in Int(((arrived - boundary) * 1000).rounded()) }
                kept += out.frames
            }
            kept += pendingWarmFrames
            pendingWarmFrames = []
        } else if scenario == .builtinStartSlow {
            let offset = time - boundary
            if offset + 1e-9 >= slowStartAt, !slowUnit.isStarted, !builtinStopped {
                slowUnit.startReturned()
                feed.sourceStarted(.builtin, at: time)
            }
            // The recorder's health tick: the device read-back of the active built-in, every 100 ms (v1.8 L1),
            // judged by the production policy (v1.27 B1: never before the start returned; unreadable re-read).
            if !builtinStopped, !slowDriftNoted, let check = slowUnit.deviceCheck() {
                switch BuiltinWatch.judge(check, headsetStarting: feed.health.headsetStarting(at: time), rebuilt: slowRebuilt) {
                case .none: slowUnreadable = false
                case .recheck:
                    if !slowUnreadable { notes.append(check.note) }
                    slowUnreadable = true
                case .rebuild(let problem):
                    notes += [check.note, "builtin_rebuilt=1 reason=\(problem.rawValue)"]
                    slowRebuilt = true
                    feed.builtinRestarting()
                    slowUnit.reset()
                    slowStartAt = offset + 0.1
                case .dead(let problem):
                    slowDriftNoted = true
                    feed.deviceProblem(.builtin, problem)
                    notes.append(check.note)
                }
            }
            var outs: [CaptureFeed.Output] = []
            if slowUnit.isStarted, !builtinStopped { outs.append(feed.accept(wav, source: .builtin, at: time)) }
            if offset + 1e-9 >= Self.slowHeadsetStartReturnsAt {
                if feed.health.headsetInFlight { feed.headsetStart(inFlight: false) }
                outs.append(feed.accept(wav, source: .headset, at: time))
            }
            for out in outs {
                notes += out.notes
                kept += out.frames
            }
        } else if scenario.hasHeadset {
            // Built-in = the WAV (until it dies), headset = digital zeros, same 100 ms window.
            let dying = scenario == .builtinDies || scenario == .builtinDrifts
            if dying, !builtinStopped, time - boundary >= Self.builtinLifetime {
                builtinStopped = true
                if scenario == .builtinDrifts {
                    // v1.27 (B1): through the recorder's policy — the headset is already delivering (zeros), so a
                    // genuine drift is dead exactly as in v1.8 (never rebuilt).
                    let check = BuiltinPin.Check.drift(from: 154)
                    notes.append(check.note)
                    switch BuiltinWatch.judge(check, headsetStarting: feed.health.headsetStarting(at: time), rebuilt: false) {
                    case .dead(let problem): feed.deviceProblem(.builtin, problem)
                    default: notes.append("builtin_rebuilt=1 reason=drift")
                    }
                }
            }
            var outs: [CaptureFeed.Output] = []
            notes += scoNotes
            scoNotes = []
            advanceIO(to: time - boundary)
            if !builtinStopped { outs.append(feed.accept(wav, source: .builtin, at: time)) }
            if let headset = headsetChunk(offset: time - boundary, wav: wav) {
                if scenario == .scoTornDown250ms {
                    // v1.12 (L2): IO observed again discharges the stopped engine's obligation.
                    ioGuard.headsetFrames(headset.count, peak: headset.reduce(Float(0)) { max($0, abs($1)) },
                                          at: time - boundary + 0.1)
                    _ = ioGuard.observe(at: time - boundary + 0.1, engineRunning: true)
                }
                outs.append(feed.accept(headset, source: .headset, at: time))
            }
            for out in outs {
                if out.event == .fallback { notes.append("bridge_src=builtin_fallback reason=headset_digital_silence") }
                if out.event == .switchback { notes.append("bridge_switchback=1") }
                if out.event == .recovered { notes.append("bridge_switch=headset reason=recovered") }
                if let fresh = out.fallbackFresh {
                    notes.append("fallback_check builtin_fresh_at_fallback=\(fresh ? 1 : 0) builtin_age_ms=\(out.builtinAgeMs.map(String.init) ?? "none")\(out.fallbackRefused ? " refused=1" : "")")
                }
                if out.restartHeadset, scenario == .headsetTakeover {
                    notes.append("bt_recovery=coalesced path=restart")
                } else if out.restartHeadset {
                    feed.headsetRestarted()
                    notes.append("headset_restart=1 simulated=1")
                    requestRestart(at: time - boundary)
                }
                kept += out.frames
            }
        } else {
            kept = feed.accept(wav, source: .headset, at: time).frames
        }
        // The production health clock, on the same media clock.
        var failure: CaptureFailure?
        if !failed {
            let health = feed.tick(at: mediaTime)
            kept += health.frames
            notes += health.notes
            if scenario == .builtinStartSlow, health.stopBuiltin { builtinStopped = true }
            // transient_hfp: what is due at this instant (a verification's verdict) lands before the observation,
            // as in f243a0c8 (`settled … silent_frames` → `escalate`).
            if scenario == .transientHFP { notes += warmAdvance(to: mediaTime + 1e-6) }
            if scenario.hfpModel { notes += warmObserve(at: mediaTime) }
            // Plain injection delivers a frame on every tick by construction, so exact zeros (leading, between
            // words, EOF tail) are the fixture's silence, not a dead mic. Only the dead-stream scenarios judge it.
            if let found = health.failure, scenario != .plain { failed = true; failure = found; notes.append(found.note) }
        }
        buffer.append(contentsOf: kept)
        // Exact inverse of the /32768 above: the WAV's samples arrive unchanged.
        pendingPCM += kept.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) }
        let pcmCb = onPCMChunk
        if let pcmCb {
            while pendingPCM.count >= AudioRecorder.chunkSamples {
                delivery.enqueue(Array(pendingPCM.prefix(AudioRecorder.chunkSamples)), to: pcmCb)
                pendingPCM.removeFirst(AudioRecorder.chunkSamples)
            }
        }

        let shouldFireFirst = !firstBufferFired
        if shouldFireFirst {
            firstBufferFired = true
        }
        // Levels only from frames the dictation kept (v1.8: none are fabricated).
        let level: Double? = kept.isEmpty ? nil : meter.level(db: WisprLevel.db(samples: kept))

        let tickMs = Int(((mediaTime - boundary) * 1000).rounded())
        for (index, line) in notes.enumerated() { timedNotes.append((index < noteTimes.count ? noteTimes[index] : tickMs, line)) }
        let firstCb = shouldFireFirst ? onFirstBuffer : nil
        let levelCb = onLevel
        let failureCb = onCaptureFailure
        lock.unlock()

        let sink = note
        for line in notes { sink(line) }
        // Same threads as AudioRecorder: PCM from the capture queue, first-buffer and level on main.
        delivery.drain()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }   // dropped after stop(), like the real epoch check
            firstCb?()
            if let level { levelCb?(level) }
            if let failure { failureCb?(failure) }
        }
    }

    @discardableResult public func stop() -> [Float] {
        lock.lock()
        if let t = timer {
            t.setEventHandler(handler: nil)
            t.cancel()
            timer = nil
        }
        manualRunning = false
        let captured = buffer
        buffer.removeAll()
        firstBufferFired = false
        var remainder: [Int16] = []
        if feed.bridge.state != .off {
            if scenario.hasHeadset {
                stats.bridgeSource = feed.bridge.bridgeSource
                stats.bridgeReason = feed.bridge.reason
                stats.headsetRestart = feed.bridge.restart?.result
                stats.bridgeSwitchback = feed.bridge.switchbacks
                stats.builtinFramesAfterFallback = feed.bridge.builtinFramesAfterFallback
            }
            stats.captureIntervals = feed.evidence.intervalsNote
            stats.speechSections = feed.evidence.finalSpeechSections
            levelEnvelope = feed.evidence.levelEnvelope
            stats.recordingMs = max(0, Int(((mediaTime - boundary) * 1000).rounded()))
            if scenario == .scoTornDown250ms {
                advanceIO(to: mediaTime - boundary)
                ioGuard.record(.stop)                   // the end-of-dictation teardown
            }
            stats.ioOps = scenario == .transientHFP ? warmIO.note : ioGuard.note
            stats.ioHeld = scenario == .transientHFP ? warmIO.heldNote : ioGuard.heldNote
            stats.carrier = feed.timeline.carrierIntervals(endMs: stats.recordingMs)
            stats.headsetCarriedMs = feed.timeline.headsetIntervalMs(endMs: stats.recordingMs)
            stats.captureIntervalsTruncated = feed.evidence.truncated
            stats.carrierFrames = feed.timeline.framesNote
            feed.cancel()
            remainder = pendingPCM
            pendingPCM.removeAll()
        }
        let pcmCb = onPCMChunk
        lock.unlock()
        if !remainder.isEmpty, let pcmCb { delivery.enqueue(remainder, to: pcmCb) }
        delivery.drain()
        return captured
    }

    public func release() {
        _ = stop()
    }

    public func rebuild() throws {}

    public func rebuildAsync() async throws {}

    public func resetCapture() {
        lock.withLock {
            buffer.removeAll(keepingCapacity: true)
            sampleCursor = 0
            firstBufferFired = false
            meter.clearBatch()
            pendingPCM.removeAll()
            if feed.bridge.state != .off { boundaryAt(mediaTime) }
        }
    }
}

/// v1.27 B1 (`builtin_start_slow`): the built-in AUHAL as observed in cc891096 — its device resolves at once
/// (`expectedDeviceID`), but the unit's device property is unreadable until `start(epoch:)` returns.
final class InjectedBuiltinUnit: BuiltinCapture {
    var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
    var onDeviceLost: ((CaptureEpoch) -> Void)?
    private(set) var isStarted = false
    var started: Bool { isStarted }
    func reset() { isStarted = false }
    func startReturned() { isStarted = true }
    func start(epoch: CaptureEpoch) throws { isStarted = true }
    func stop() { isStarted = false }
    func stop(epoch: CaptureEpoch) { stop() }
    var isDelivering: Bool { isStarted }
    var currentDeviceID: UInt32? { isStarted ? 81 : nil }
    var expectedDeviceID: UInt32? { 81 }
    var lastBufferTime: TimeInterval? { nil }
    let backend = "injected"
}
