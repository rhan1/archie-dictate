import Foundation

/// v1.8 (L2): per-source liveness, evaluated on an independent 100 ms clock that the
/// recorder owns (never driven by tap callbacks). Pure: every time is a host-clock second
/// passed in, so tests drive it with a fake clock and no hardware.
///
/// A source is `stale` after `staleAfter` without fresh frames once it has delivered (or
/// when it never delivers within its startup grace), `transport-silent` after `zerosAfter`
/// of exact zeros (a dropped eSCO link injects them) — distinct from quiet speech, which is
/// non-zero and never a fault — and `dead` when stale or its device drifted/disappeared.
public struct CaptureHealth: Sendable {
    public typealias Source = CaptureBridge.Source
    public static let tickInterval: TimeInterval = 0.1
    public static let staleAfter: TimeInterval = 0.6
    public static let builtinGrace: TimeInterval = 1.0
    /// While a healthy built-in carries, the headset may take this long to deliver at all.
    public static let headsetGrace: TimeInterval = 2.0
    public static let zerosAfter: TimeInterval = 1.5
    /// A switch target must have delivered within this long ...
    public static let freshWithin: TimeInterval = 0.3
    /// ... with at least this much consecutive non-zero signal.
    public static let switchSignal: TimeInterval = 0.15
    /// Nothing useful arriving: the dictation ends this long after the last useful delivery
    /// (or the recording boundary). Absolute: a recovery attempt never moves it.
    public static let failAfter: TimeInterval = 2.0
    public static let silencePeak: Float = CaptureBridge.silencePeak
    private static let rate = 24_000.0

    public enum Problem: String, Sendable { case stale, drift, lost }
    public enum Status: Equatable, Sendable { case absent, starting, healthy, zeros, dead(Problem) }
    public enum Reason: String, Sendable {
        case noInput = "no_input", staleBuiltin = "stale_builtin", staleHeadset = "stale_headset", zeros
    }
    /// What the owner applies, in this order, under its state lock.
    public enum Action: Equatable, Sendable {
        /// The built-in can no longer carry this dictation: stop it and stop counting on it.
        case builtinDead(Problem)
        /// The carrying source is dead or transport-silent and `to` is fresh with signal.
        case switchTo(Source, reason: Reason)
        /// Nothing useful is arriving and nothing fresh can take over (shown at once).
        case warn(Reason)
        /// The deadline passed: end the dictation with `mic_dead`.
        case fail(Reason)
    }

    struct SourceState: Sendable {
        var active = false
        var startedAt: TimeInterval?
        var firstAt: TimeInterval?
        var lastAt: TimeInterval?
        var zeroSince: TimeInterval?
        var signalRun: TimeInterval = 0
        var problem: Problem?
        var everSignal = false
    }
    private var builtin = SourceState()
    private var headset = SourceState()
    public private(set) var boundary: TimeInterval?
    public private(set) var lastUseful: TimeInterval?
    public private(set) var warned: Reason?
    public private(set) var failed: Reason?
    private var builtinReported = false

    public init() {}

    private func state(_ source: Source) -> SourceState { source == .builtin ? builtin : headset }
    private mutating func update(_ source: Source, _ change: (inout SourceState) -> Void) {
        if source == .builtin { change(&builtin) } else { change(&headset) }
    }

    /// The recorder asked this source to start (grace is measured from here).
    public mutating func sourceStarted(_ source: Source, at time: TimeInterval) {
        update(source) { s in
            if !s.active || s.problem != nil { s = SourceState() }
            s.active = true
            if s.startedAt == nil { s.startedAt = time }
        }
    }
    /// The source is no longer part of this dictation (stopped or never selected).
    public mutating func sourceRemoved(_ source: Source) { update(source) { $0.active = false } }

    public mutating func recordingStarted(at time: TimeInterval) {
        boundary = time
        lastUseful = nil
        warned = nil
        failed = nil
    }

    /// A converted buffer arrived (`time` = arrival on the host clock). Returns true when this
    /// buffer completed `switchSignal` of signal after a stretch without it (the gate's
    /// `headset_signal_start=1`).
    @discardableResult
    public mutating func buffer(_ source: Source, at time: TimeInterval, frames: Int, peak: Float) -> Bool {
        guard frames > 0 else { return false }
        var started = false
        update(source) { s in
            // A source that delivers is part of the dictation even without an explicit start.
            if !s.active { s.active = true }
            if s.startedAt == nil { s.startedAt = time }
            if s.firstAt == nil { s.firstAt = time }
            s.lastAt = time
            let seconds = Double(frames) / Self.rate
            if peak < Self.silencePeak {
                if s.zeroSince == nil { s.zeroSince = time - seconds }
                s.signalRun = 0
            } else {
                s.zeroSince = nil
                let before = s.signalRun
                s.signalRun += seconds
                if before < Self.switchSignal, s.signalRun >= Self.switchSignal { started = true; s.everSignal = true }
            }
        }
        return started
    }

    /// Kept frames entered the dictation; non-zero ones are a useful delivery.
    public mutating func kept(at time: TimeInterval, peak: Float) {
        guard peak >= Self.silencePeak else { return }
        lastUseful = time
    }

    /// The device read-back or the device listener found a problem.
    public mutating func deviceProblem(_ source: Source, _ problem: Problem) {
        update(source) { if $0.active, $0.problem == nil { $0.problem = problem } }
    }

    public func status(_ source: Source, at now: TimeInterval) -> Status {
        let s = state(source)
        guard s.active else { return .absent }
        if let problem = s.problem { return .dead(problem) }
        guard let last = s.lastAt else {
            let grace = source == .builtin ? Self.builtinGrace : Self.headsetGrace
            if let started = s.startedAt, now - started > grace { return .dead(.stale) }
            return .starting
        }
        if now - last > Self.staleAfter { return .dead(.stale) }
        if let zero = s.zeroSince, now - zero >= Self.zerosAfter { return .zeros }
        return .healthy
    }

    /// Fresh enough to take over: delivered within `freshWithin`, with `switchSignal` of signal.
    public func isFresh(_ source: Source, at now: TimeInterval) -> Bool {
        let s = state(source)
        guard s.active, s.problem == nil, let last = s.lastAt else { return false }
        return now - last <= Self.freshWithin && s.zeroSince == nil && s.signalRun >= Self.switchSignal
    }

    /// Age of the source's last buffer in ms (nil: none yet).
    public func ageMs(_ source: Source, at now: TimeInterval) -> Int? {
        state(source).lastAt.map { max(0, Int(((now - $0) * 1000).rounded())) }
    }
    public func lastBufferTime(_ source: Source) -> TimeInterval? { state(source).lastAt }

    /// `builtin:dead,headset:zeros` for the failure line.
    public func summary(at now: TimeInterval) -> String {
        func word(_ status: Status) -> String {
            switch status {
            case .absent: return "absent"
            case .starting: return "starting"
            case .healthy: return "ok"
            case .zeros: return "zeros"
            case .dead(let problem): return problem == .stale ? "dead" : problem.rawValue
            }
        }
        return "builtin:\(word(status(.builtin, at: now))),headset:\(word(status(.headset, at: now)))"
    }

    /// One 100 ms evaluation. `carrying` is the source whose frames currently enter the
    /// dictation (nil before the recording boundary: nothing is evaluated).
    public mutating func tick(at now: TimeInterval, carrying: Source?) -> [Action] {
        var actions: [Action] = []
        if !builtinReported, case .dead(let problem) = status(.builtin, at: now) {
            builtinReported = true
            actions.append(.builtinDead(problem))
        }
        guard let boundary, failed == nil else { return actions }
        guard let carrying else {
            // No source configured yet (start still in flight): the never-first-buffer deadline runs anyway.
            guard lastUseful == nil else { return actions }
            if warned == nil, now - boundary > Self.builtinGrace { warned = .noInput; actions.append(.warn(.noInput)) }
            if now >= boundary + Self.failAfter { failed = .noInput; actions.append(.fail(.noInput)) }
            return actions
        }
        let other: Source = carrying == .builtin ? .headset : .builtin
        let reason: Reason?
        switch status(carrying, at: now) {
        case .healthy: reason = nil
        case .zeros: reason = .zeros
        case .starting: reason = nil
        case .absent: reason = .noInput
        case .dead:
            if state(carrying).lastAt == nil { reason = .noInput }
            else { reason = carrying == .builtin ? .staleBuiltin : .staleHeadset }
        }
        if let reason, isFresh(other, at: now) {
            actions.append(.switchTo(other, reason: reason))
            warned = nil
            return actions
        }
        let usefulNow = reason == nil && lastUseful.map { now - $0 <= Self.staleAfter } == true
        if usefulNow { warned = nil; return actions }
        // Nothing useful is arriving (dead/silent carrier, or still waiting for a first buffer).
        let deadline = (lastUseful ?? boundary) + Self.failAfter
        let shown = reason ?? (lastUseful == nil && now - boundary > Self.builtinGrace ? .noInput : nil)
        if let shown, warned == nil {
            warned = shown
            actions.append(.warn(shown))
        }
        if now >= deadline {
            // The first problem shown is the cause (21:33: the built-in died, then only zeros were left).
            let final = warned ?? reason ?? .noInput
            failed = final
            actions.append(.fail(final))
        }
        return actions
    }
}

/// v1.8: why the recorder ended a dictation on its own, with what it had kept.
public struct CaptureFailure: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The health clock found no useful input (L2): outcome `error:mic_dead`.
        case micDead = "mic_dead"
        /// An engine failed for good with nothing else carrying (today's `mic_start`).
        case engine
    }
    public var reason: Reason
    public var health: CaptureHealth.Reason?
    public var durationSeconds: Double
    public var bytes: Int
    public var framesKept: Int
    public var lastDeliveryMs: Int?
    public var sources: String
    public init(reason: Reason, health: CaptureHealth.Reason? = nil, durationSeconds: Double = 0, bytes: Int = 0,
                framesKept: Int = 0, lastDeliveryMs: Int? = nil, sources: String = "") {
        self.reason = reason; self.health = health; self.durationSeconds = durationSeconds; self.bytes = bytes
        self.framesKept = framesKept; self.lastDeliveryMs = lastDeliveryMs; self.sources = sources
    }
    public var keptMs: Int { Int((Double(framesKept) / 24.0).rounded()) }
    /// `fail reason=mic_dead kept_ms=… last_delivery_ms=… sources=builtin:dead,headset:zeros`
    public var note: String {
        var line = "fail reason=\(reason.rawValue)"
        if let health { line += " health=\(health.rawValue)" }
        line += " kept_ms=\(keptMs) last_delivery_ms=\(lastDeliveryMs.map(String.init) ?? "none")"
        line += " duration_ms=\(Int((durationSeconds * 1000).rounded())) bytes=\(bytes)"
        if !sources.isEmpty { line += " sources=\(sources)" }
        return line
    }
}
