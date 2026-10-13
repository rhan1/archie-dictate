import Foundation

/// Bounded pre-roll store for 24 kHz mono frames that arrive between the first
/// ⌥ tap and the recording boundary (host-clock timestamps). The oldest frames
/// are overwritten; nothing here ever leaves memory.
public struct CaptureRing {
    public static let sampleRate: Double = 24_000
    /// Audio kept from before the second tap.
    public static let preRoll: TimeInterval = 0.15
    /// 1.0 s at the pipeline rate: longer than the 0.7 s double-tap window.
    public static let defaultCapacity = 24_000
    public let capacity: Int
    public private(set) var count = 0
    private var storage: [Float]
    private var head = 0
    // Contiguous runs, oldest first: a gap or a source handover keeps its own timestamp.
    private struct Run { var time: TimeInterval; var count: Int }
    private var runs: [Run] = []

    public init(capacity: Int = CaptureRing.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    /// Host time of the oldest stored frame.
    public var oldestTime: TimeInterval? { runs.first?.time }
    /// Host time just past the newest stored frame.
    public var newestEnd: TimeInterval? { runs.last.map { $0.time + Double($0.count) / Self.sampleRate } }

    public mutating func append(_ frames: [Float], at time: TimeInterval) {
        guard !frames.isEmpty else { return }
        let skip = max(0, frames.count - capacity)
        let time = time + Double(skip) / Self.sampleRate
        let incoming = frames.count - skip
        if count + incoming > capacity { dropOldest(count + incoming - capacity) }
        var index = (head + count) % capacity
        for frame in frames[skip...] {
            storage[index] = frame
            index = index + 1 == capacity ? 0 : index + 1
        }
        if let last = runs.last,
           abs(last.time + Double(last.count) / Self.sampleRate - time) < 0.5 / Self.sampleRate {
            runs[runs.count - 1].count += incoming
        } else {
            runs.append(Run(time: time, count: incoming))
        }
        count += incoming
    }

    /// Every stored frame captured at or after `time`, oldest first; empties the ring.
    public mutating func drain(from time: TimeInterval) -> [Float] {
        var kept: [Float] = []
        var offset = 0
        for run in runs {
            let skip = min(run.count, max(0, Int(ceil((time - run.time) * Self.sampleRate - 0.000001))))
            for i in (offset + skip)..<(offset + run.count) { kept.append(storage[(head + i) % capacity]) }
            offset += run.count
        }
        removeAll()
        return kept
    }

    public mutating func removeAll() {
        head = 0
        count = 0
        runs.removeAll()
    }

    private mutating func dropOldest(_ frames: Int) {
        var remaining = min(frames, count)
        head = (head + remaining) % capacity
        count -= remaining
        while remaining > 0, !runs.isEmpty {
            if runs[0].count <= remaining {
                remaining -= runs[0].count
                runs.removeFirst()
            } else {
                runs[0].count -= remaining
                runs[0].time += Double(remaining) / Self.sampleRate
                remaining = 0
            }
        }
    }
}

/// The recorder's single serialized path for converted frames: source
/// arbitration (CaptureBridge), the pre-roll ring before the second tap, and the
/// frames that enter the dictation after it. The owner holds its lock around
/// every call, exactly as it did for the bridge alone.
///
/// v1.8: also the per-source health (CaptureHealth, ticked by the owner's 100 ms clock) and the
/// counts-only capture evidence (CaptureEvidence) the session-end note carries.
public struct CaptureFeed {
    public struct Output: Equatable, Sendable {
        public var frames: [Float] = []
        public var releaseBuiltin = false
        /// These are the first kept frames after the second tap (cold start).
        public var firstKept = false
        public var restartHeadset = false
        public var event: CaptureBridge.Event?
        /// v1.8: the headset just completed `switchSignal` of signal (`headset_signal_start=1`).
        public var headsetSignalStart = false
        /// v1.8: with a `.fallback` event, whether the built-in was fresh, and its buffer age.
        public var fallbackFresh: Bool?
        public var builtinAgeMs: Int?
        public var fallbackRefused = false
    }
    /// One health-clock evaluation's effects, applied by the owner after its lock.
    public struct TickOutput: Equatable, Sendable {
        public var frames: [Float] = []
        public var notes: [String] = []
        public var stopBuiltin = false
        public var warn: CaptureHealth.Reason?
        public var failure: CaptureFailure?
    }
    public private(set) var bridge = CaptureBridge()
    public private(set) var ring: CaptureRing
    public private(set) var health = CaptureHealth()
    public private(set) var evidence = CaptureEvidence()
    /// v1.12 (L1): which source carried every kept frame (the session line's `carrier=`).
    public private(set) var timeline = SourceTimeline()
    /// While the headset carries, the built-in's latest frames wait here so a switchback
    /// resumes exactly where the headset stopped (the buffer that crossed the switch
    /// arrived before the decision). 1.5 s covers the stale-headset wait (1.0 s) plus one buffer.
    private var standby = CaptureRing(capacity: 36_000)

    public init(ringCapacity: Int = CaptureRing.defaultCapacity) {
        ring = CaptureRing(capacity: ringCapacity)
    }

    public mutating func start(defaultInput: CaptureBridge.DefaultInput, hasBuiltin: Bool,
                               epoch: CaptureEpoch = CaptureEpoch()) {
        bridge.start(defaultInput: defaultInput, hasBuiltin: hasBuiltin, epoch: epoch)
        ring.removeAll()
        standby.removeAll()
        health = CaptureHealth()
        evidence = CaptureEvidence()
        timeline = SourceTimeline()
    }

    /// The owner asked a source's hardware to start (its startup grace runs from here).
    public mutating func sourceStarted(_ source: CaptureBridge.Source, at time: TimeInterval) {
        health.sourceStarted(source, at: time)
    }
    /// The device read-back or listener found a problem with a source.
    public mutating func deviceProblem(_ source: CaptureBridge.Source, _ problem: CaptureHealth.Problem) {
        health.deviceProblem(source, problem)
    }

    /// The source whose frames currently enter the dictation (nil before the second tap).
    public var carrying: CaptureBridge.Source? {
        guard bridge.isRecording else { return nil }
        switch bridge.state {
        case .off: return nil
        case .builtinOnly, .fallback: return .builtin
        case .switched: return .headset
        }
    }

    public mutating func accept(_ frames: [Float], source: CaptureBridge.Source, at time: TimeInterval,
                                arrivedAt: TimeInterval? = nil, epoch: CaptureEpoch? = nil) -> Output {
        if let epoch, epoch !== bridge.epoch { return Output() }
        let now = arrivedAt ?? time
        let hadKept = bridge.firstKeptMs != nil
        let peak = Self.peak(frames[...])
        let signalStart = health.buffer(source, at: now, frames: frames.count, peak: peak)
        let builtinFresh = health.isFresh(.builtin, at: now)
        let decision = bridge.buffer(source: source, at: time, frames: frames.count,
                                     arrivedAt: arrivedAt, epoch: epoch, peak: peak, builtinFresh: builtinFresh)
        var output = Output(releaseBuiltin: decision.releaseBuiltin,
                            restartHeadset: decision.restartHeadset, event: decision.event)
        output.headsetSignalStart = source == .headset && signalStart
        output.fallbackRefused = decision.fallbackRefused
        if decision.event == .fallback || decision.fallbackRefused {
            output.fallbackFresh = decision.event == .fallback
            output.builtinAgeMs = health.ageMs(.builtin, at: now)
        }
        let trimmed = frames.dropFirst(decision.dropFrames)
        if decision.framesToRing > 0 {
            ring.append(Array(trimmed.prefix(decision.framesToRing)),
                        at: time + Double(decision.dropFrames) / CaptureRing.sampleRate)
        }
        let fed = trimmed.prefix(decision.framesToFeed)
        output.frames = Array(fed)
        keep(fed, source: source, at: time + Double(decision.dropFrames) / CaptureRing.sampleRate, arrivedAt: now)
        if source == .builtin, bridge.canSwitchBack || decision.event == .switchback {
            standby.append(frames, at: time)
        }
        if decision.event == .switchback { output.frames += resumeBuiltin(arrivedAt: now) }
        output.firstKept = !hadKept && bridge.firstKeptMs != nil
        return output
    }

    private static func peak(_ frames: ArraySlice<Float>) -> Float {
        frames.reduce(Float(0)) { max($0, abs($1)) }
    }

    /// Frames that entered the dictation: evidence, the source timeline + useful-delivery time.
    private mutating func keep(_ frames: ArraySlice<Float>, source: CaptureBridge.Source, at time: TimeInterval,
                               arrivedAt: TimeInterval) {
        guard bridge.isRecording, !frames.isEmpty else { return }
        evidence.append(frames, at: time)
        timeline.append(source, frames: frames.count, at: time)
        health.kept(at: arrivedAt, peak: Self.peak(frames))
    }

    /// The standby built-in frames from where the headset stopped (into the ring before the second tap).
    private mutating func resumeBuiltin(arrivedAt: TimeInterval? = nil) -> [Float] {
        let end = standby.newestEnd
        let resumed = standby.drain(from: bridge.fedThroughTime ?? 0)
        guard let end, !resumed.isEmpty else { return [] }
        bridge.resumedBuiltin(frames: resumed.count, through: end)
        let start = end - Double(resumed.count) / CaptureRing.sampleRate
        if bridge.isRecording {
            keep(resumed[...], source: .builtin, at: start, arrivedAt: arrivedAt ?? end)
            return resumed
        }
        ring.append(resumed, at: start)
        return []
    }

    /// The headset engine failed for good: the built-in carries on from where the headset
    /// stopped. Returns the event (nil: nothing carries) and the frames to append.
    /// v1.8: with `now`, a live built-in that is not fresh is not chosen; `deferred` = the
    /// health clock decides (a switch if it turns fresh, else `mic_dead` at the deadline).
    public mutating func headsetFailed(at now: TimeInterval? = nil)
        -> (event: CaptureBridge.Event?, frames: [Float], deferred: Bool) {
        if let now, bridge.builtinIsAlive, bridge.state != .off, !health.isFresh(.builtin, at: now) {
            return (nil, [], true)
        }
        let switching = bridge.state == .switched
        let event = bridge.headsetFailed()
        return (event, switching && event == .switchback ? resumeBuiltin() : [], false)
    }

    /// The second tap: keeps ring audio from `time − preRoll` and returns it.
    public mutating func recordingStarted(at time: TimeInterval,
                                          preRoll: TimeInterval = CaptureRing.preRoll) -> [Float] {
        let end = ring.newestEnd
        let kept = ring.drain(from: time - preRoll)
        bridge.recordingStarted(at: time, preRoll: preRoll, keptFrames: kept.count)
        health.recordingStarted(at: time)
        evidence.start(at: time)
        timeline.start(at: time)
        if let end, !kept.isEmpty {
            // The ring holds what the arbitration fed before the boundary: the carrying source's
            // frames (a handover inside the 150 ms pre-roll is attributed to the source at the boundary).
            keep(kept[...], source: carrying ?? .builtin, at: end - Double(kept.count) / CaptureRing.sampleRate,
                 arrivedAt: time)
        }
        return kept
    }

    /// One 100 ms health evaluation (v1.8 L2). Switches are applied here; the owner stops a dead
    /// built-in, shows the warning, and ends the dictation on `failure`.
    public mutating func tick(at now: TimeInterval) -> TickOutput {
        var out = TickOutput()
        // Also before the bridge is configured: the boundary's never-first-buffer deadline runs.
        guard bridge.state != .off || bridge.isRecording else { return out }
        for action in health.tick(at: now, carrying: carrying) {
            switch action {
            case .builtinDead(let problem):
                let before = bridge.state
                bridge.builtinDied()
                out.stopBuiltin = true
                out.notes.append("bridge_builtin_lost=1 reason=\(problem.rawValue) state=\(before)")
            case .switchTo(.headset, let reason):
                bridge.takeOver()
                out.notes.append("bridge_switch=headset reason=\(reason.rawValue)")
            case .switchTo(.builtin, let reason):
                guard bridge.canSwitchBack else { continue }
                bridge.headsetStalled(stale: reason != .zeros)
                out.frames += resumeBuiltin(arrivedAt: now)
                out.notes.append("bridge_switchback=1 reason=\(reason.rawValue)")
            case .warn(let reason):
                out.warn = reason
                out.notes.append("health=warn reason=\(reason.rawValue)")
            case .fail(let reason):
                out.failure = failure(reason: reason, at: now)
            }
        }
        return out
    }

    /// What was kept so far, for a `mic_dead` failure (real duration and bytes, never zero).
    public func failure(reason: CaptureHealth.Reason, at now: TimeInterval) -> CaptureFailure {
        let boundary = health.boundary ?? now
        return CaptureFailure(reason: .micDead, health: reason, durationSeconds: max(0, now - boundary),
                              bytes: 44 + evidence.framesKept * 2, framesKept: evidence.framesKept,
                              lastDeliveryMs: health.lastUseful.map { max(0, Int((($0 - boundary) * 1000).rounded())) },
                              sources: health.summary(at: now))
    }

    /// Lone tap, finish or cancel: the ring is discarded with the session.
    /// Returns true when the bridge still owned the built-in input.
    @discardableResult public mutating func cancel() -> Bool {
        ring.removeAll()
        standby.removeAll()
        health = CaptureHealth()
        return bridge.cancel()
    }

    public mutating func builtinFailed() { bridge.builtinFailed() }
    public mutating func headsetRestarted(started: Bool = true) { bridge.headsetRestarted(started: started) }
}
