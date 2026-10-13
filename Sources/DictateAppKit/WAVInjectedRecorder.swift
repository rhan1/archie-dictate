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
public final class WAVInjectedRecorder: EngineRecorder {
    /// Which re-attach the `sco_torn_down_250ms` IO model runs.
    public enum IOPolicy: Sendable { case v19, v110 }
    public enum Scenario: String, Sendable {
        case plain, headsetZeros = "headset_zeros", builtinDies = "builtin_dies", builtinDrifts = "builtin_drifts"
        case scoTornDown250ms = "sco_torn_down_250ms"
        case headsetTakeover = "headset_takeover"
        var hasHeadset: Bool { self != .plain }
    }
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

    public var isRunning: Bool { lock.withLock { timer != nil } }
    public var isAllocated: Bool { lock.withLock { timer != nil } }

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

    public func start(device: MicChoice = .default) throws {
        // Parse before taking the lock: a throw must never leave it held (isRunning is read next).
        try start(parsed: Self.parseWAV(at: url))
    }

    private func start(parsed: [Int16]) throws {
        lock.lock()
        if timer != nil {
            lock.unlock()
            return
        }
        wavSamples = parsed
        sampleCursor = 0
        firstBufferFired = false
        buffer.removeAll()
        meter.clearBatch()
        pendingPCM.removeAll()
        mediaTime = 1_000
        feed.start(defaultInput: scenario.hasHeadset ? .bluetooth : .other, hasBuiltin: scenario.hasHeadset)
        if scenario.hasHeadset { feed.sourceStarted(.builtin, at: mediaTime) }
        feed.sourceStarted(.headset, at: mediaTime)
        boundaryAt(mediaTime)

        let timerSource = DispatchSource.makeTimerSource(queue: queue)
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

    /// Parses off the caller's actor (the controller calls this from the main actor).
    public func startAsync(device: MicChoice = .default) async throws {
        if isRunning { return }
        let url = self.url
        let parsed = try await Task.detached { try Self.parseWAV(at: url) }.value
        try start(parsed: parsed)
    }

    private func tick() {
        lock.lock()
        guard timer != nil, mediaLimit.map({ mediaTime - boundary < $0 - 1e-9 }) ?? true else {
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
        if scenario.hasHeadset {
            // Built-in = the WAV (until it dies), headset = digital zeros, same 100 ms window.
            let dying = scenario == .builtinDies || scenario == .builtinDrifts
            if dying, !builtinStopped, time - boundary >= Self.builtinLifetime {
                builtinStopped = true
                if scenario == .builtinDrifts {
                    feed.deviceProblem(.builtin, .drift)
                    notes.append(BuiltinPin.Check.drift(from: 154).note)
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
            if let found = health.failure { failed = true; failure = found; notes.append(found.note) }
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
            stats.ioOps = ioGuard.note
            stats.ioHeld = ioGuard.heldNote
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
