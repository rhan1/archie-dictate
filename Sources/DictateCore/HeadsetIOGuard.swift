import Foundation

/// v1.10 (L1) → v1.12 (L2): every engine operation DictateKit performs on the headset during one
/// dictation, and the Bluetooth recovery rule — now anchored to OBSERVED IO state instead of a
/// blind 1.0 s hands-off window (GPT-6 review §A "What I would do" 1–2, rank 5).
///
/// 10-13 07:00–07:10 (Archie 38.0, XM6): our IO context started/stopped ~6 times in the first
/// 1.3 s of every A2DP-start dictation; each stop while the SCO link was forming dropped eSCO
/// creation. v1.10 answered with "one re-attach from the first notification, then nothing for
/// 1.0 s". The review found its hole: a SECOND stopped-engine notification inside that window
/// was swallowed (`handsOff`), so a stopped engine could sit stopped with no one owing it a
/// re-attach, and `convertsInTap` stayed on for the guard's whole lifetime.
///
/// v1.12 rule (Bluetooth input):
/// - A stopped engine — reported by a configuration notification, or OBSERVED stopped by the
///   100 ms health clock while capture should be running ("config running at 0 ms; auto-stop at
///   200 ms; no frames thereafter") — opens a recovery OBLIGATION. It stays open, visible on the
///   session line, until IO is observed again (fresh headset frames after the re-attach).
/// - An open obligation gets a re-attach as soon as none is in flight. A re-attach is IN FLIGHT
///   from its start until fresh headset frames arrive (IO completed), its start fails, or
///   `inFlightBound` passes without frames. Nothing else touches the engine while one is in
///   flight (that keeps v1.10's protection against churn while the SCO link forms), but the
///   bound is a ceiling, not a blind wait: observed frames end it early.
/// - At most `maxReattaches` re-attaches per dictation; past that the obligation stays open
///   (`io_obligation=open`) and the episode/health clock decide — bounded, never a spin.
/// - A notification that finds the engine still running is left alone while recovery is
///   unsettled; once the headset delivered SUSTAINED usable signal (the bridge's takeover test,
///   `CaptureBridge.takeoverSignal` of consecutive non-silent frames — never one nonzero buffer)
///   the format generation is settled and later notifications go to the episode again.
/// - The tap converts in place (`convertsInTap`) only while the current format generation is
///   unsettled; after sustained signal `TapFormatPlan`'s rebuild/align may run again.
///
/// Operations are counted as attempted / completed / failed, and the OS's own engine stops
/// (`framework`) separately: an application counter cannot prove the HAL did not stop IO.
/// Other inputs are counted but never held.
public struct HeadsetIOGuard: Sendable {
    public enum Op: String, Sendable, CaseIterable { case start, stop, rebuild, retap, align }
    /// Upper bound of one re-attach's wait for fresh frames (= the episode's verification window).
    public static let inFlightBound: TimeInterval = BluetoothRecoveryEpisode.successWithin
    /// v1.10's name for the bound (kept for the live protocol's vocabulary).
    public static let handsOff: TimeInterval = inFlightBound
    /// Re-attaches per dictation.
    public static let maxReattaches = 3
    /// Running engine, frames had flowed, none for this long: IO ceased (a framework stop the
    /// notification did not report).
    public static let ioCeasedAfter: TimeInterval = 0.5

    public enum Reaction: Equatable, Sendable {
        /// Re-attach now (the obligation's one in-flight re-attach).
        case reattach
        /// The engine runs and recovery is unsettled: leave it alone.
        case leaveRunning
        /// A re-attach is in flight until `until` at the latest; the obligation stays open and is
        /// re-evaluated on the next observation.
        case pending(until: TimeInterval)
        /// The re-attach budget is spent; the obligation stays open (the episode decides).
        case exhausted
        /// Not Bluetooth, or no recovery open: the episode's policy decides (v1.9).
        case episode
        /// Nothing to do (an observation found IO healthy or nothing owed).
        case none
    }

    public struct Obligation: Equatable, Sendable {
        public enum Reason: String, Sendable { case engineStopped = "engine_stopped", ioCeased = "io_ceased" }
        public var since: TimeInterval
        public var reason: Reason
    }

    public let bluetooth: Bool
    // Attempted operations, per kind (v1.10's `io_ops=start:N …` counts).
    public private(set) var starts = 0
    public private(set) var stops = 0
    public private(set) var rebuilds = 0
    public private(set) var retaps = 0
    public private(set) var aligns = 0
    public private(set) var completed = 0
    public private(set) var failed = 0
    /// Engine stops the OS made (stopped-engine notifications, observed stops, ceased IO).
    public private(set) var framework = 0
    /// Configuration notifications that reached this dictation's handler.
    public private(set) var notifications = 0
    /// Operations a caller wanted while a re-attach was in flight and deferred instead.
    public private(set) var held = 0
    public private(set) var obligation: Obligation?
    public private(set) var obligationsOpened = 0
    public private(set) var obligationsDischarged = 0
    public private(set) var reattaches = 0
    /// Start of the in-flight re-attach (nil: none).
    public private(set) var inFlightSince: TimeInterval?
    /// Format generations seen (each configuration notification is one).
    public private(set) var formatGeneration = 0
    /// The current generation delivered sustained usable signal.
    public private(set) var settled = false
    private var sustained = SustainedSignal()
    private var lastHeadsetFrame: TimeInterval?

    public init(bluetooth: Bool) { self.bluetooth = bluetooth }

    public var attempted: Int { starts + stops + rebuilds + retaps + aligns }

    // MARK: Observations

    /// An `AVAudioEngineConfigurationChange` reached the engine at `now`.
    public mutating func configurationChanged(at now: TimeInterval, engineRunning: Bool) -> Reaction {
        notifications += 1
        formatGeneration += 1
        settled = false
        sustained.reset()
        guard bluetooth else { return .episode }
        if !engineRunning {
            framework += 1
            open(.engineStopped, at: now)
            return due(at: now)
        }
        if obligation != nil { return due(at: now) }
        // Running and nothing owed: leave it alone until recovery settles (or the bound passes).
        if let since = inFlightSince, now < since + Self.inFlightBound { return .leaveRunning }
        return settledOnce ? .episode : .leaveRunning
    }
    private var settledOnce = false

    /// The health clock's 100 ms observation of the headset engine while capture should run.
    /// Returns `.reattach` when an open obligation is due (the caller performs it).
    public mutating func observe(at now: TimeInterval, engineRunning: Bool) -> Reaction {
        guard bluetooth else { return .none }
        if let since = inFlightSince {
            if engineRunning, let frame = lastHeadsetFrame, frame > since {
                inFlightSince = nil
                discharge()
                return .none
            }
            if now < since + Self.inFlightBound { return .pending(until: since + Self.inFlightBound) }
            inFlightSince = nil                    // the re-attach produced no IO within its bound
        }
        if !engineRunning, obligation == nil {
            framework += 1
            open(.engineStopped, at: now)
        } else if engineRunning, obligation == nil, let frame = lastHeadsetFrame,
                  now - frame >= Self.ioCeasedAfter {
            framework += 1
            open(.ioCeased, at: now)
        }
        guard obligation != nil else { return .none }
        if engineRunning, obligation?.reason == .engineStopped, let frame = lastHeadsetFrame,
           frame > (obligation?.since ?? .infinity) {
            discharge()                            // IO came back on its own
            return .none
        }
        return due(at: now)
    }

    /// Headset frames reached the recorder at `now` (`peak`: the batch's largest |sample|).
    public mutating func headsetFrames(_ count: Int, peak: Float, at now: TimeInterval) {
        lastHeadsetFrame = now
        if sustained.add(frames: count, peak: peak, at: now) != nil { settled = true; settledOnce = true }
    }

    /// The caller could not perform the `.reattach` it was given (the episode is still verifying an
    /// attempt): un-reserve it; the obligation stays open and is due again on the next observation.
    public mutating func reattachDeclined() {
        guard inFlightSince != nil, reattaches > 0 else { return }
        reattaches -= 1
        inFlightSince = nil
        held += 1
    }

    /// The in-flight re-attach's start returned (`started == false`: it threw).
    public mutating func reattachFinished(started: Bool, at now: TimeInterval) {
        if !started { inFlightSince = nil }
    }

    // MARK: Decisions

    private mutating func open(_ reason: Obligation.Reason, at now: TimeInterval) {
        guard obligation == nil else { return }
        obligation = Obligation(since: now, reason: reason)
        obligationsOpened += 1
    }

    private mutating func discharge() {
        guard obligation != nil else { return }
        obligation = nil
        obligationsDischarged += 1
    }

    private mutating func due(at now: TimeInterval) -> Reaction {
        guard obligation != nil else { return .none }
        if let since = inFlightSince, now < since + Self.inFlightBound {
            held += 1
            return .pending(until: since + Self.inFlightBound)
        }
        guard reattaches < Self.maxReattaches else { return .exhausted }
        reattaches += 1
        inFlightSince = now
        return .reattach
    }

    /// Whether an engine stop/start/rebuild/align may run at `now` (no re-attach in flight).
    public func allows(at now: TimeInterval) -> Bool { remaining(at: now) == 0 }

    /// Seconds until the in-flight re-attach's bound (0 when operations are allowed).
    public func remaining(at now: TimeInterval) -> TimeInterval {
        guard bluetooth, let since = inFlightSince else { return 0 }
        return max(0, since + Self.inFlightBound - now)
    }

    /// The tap converts in place while the current format generation is unsettled.
    public var convertsInTap: Bool { bluetooth && formatGeneration > 0 && !settled }

    /// A caller deferred an operation because a re-attach was in flight.
    public mutating func deferred() { held += 1 }

    // MARK: Counting

    /// An operation was attempted (counted under its kind).
    public mutating func record(_ op: Op) {
        switch op {
        case .start: starts += 1
        case .stop: stops += 1
        case .rebuild: rebuilds += 1
        case .retap: retaps += 1
        case .align: aligns += 1
        }
    }
    /// The attempted operation returned (`ok`) or threw.
    public mutating func finished(_ op: Op, ok: Bool) {
        if ok { completed += 1 } else { failed += 1 }
    }

    /// Attempt + outcome around `body`: rethrows its error.
    public mutating func run<T>(_ op: Op, _ body: () throws -> T) rethrows -> T {
        record(op)
        do {
            let value = try body()
            finished(op, ok: true)
            return value
        } catch {
            finished(op, ok: false)
            throw error
        }
    }

    /// `io_ops=start:N stop:N rebuild:N retap:N attempted:N completed:N failed:N framework:N`
    /// (+ ` align:N` after `retap` only when one ran). The per-kind counts are attempts.
    public var note: String {
        "io_ops=start:\(starts) stop:\(stops) rebuild:\(rebuilds) retap:\(retaps)" + (aligns > 0 ? " align:\(aligns)" : "")
            + " attempted:\(attempted) completed:\(completed) failed:\(failed) framework:\(framework)"
    }
    /// `io_held=N config_notifications=N io_obligations=N/M io_obligation=open|none reattaches=N`
    /// (N opened / M discharged; `open` = a stopped engine was still owed IO at the end).
    public var heldNote: String {
        "io_held=\(held) config_notifications=\(notifications) io_obligations=\(obligationsOpened)/\(obligationsDischarged)"
            + " io_obligation=\(obligation.map { "open:\($0.reason.rawValue)" } ?? "none") reattaches=\(reattaches)"
    }
}

/// v1.12 (L2): the bridge's takeover test as a reusable counter — `CaptureBridge.takeoverSignal`
/// of CONSECUTIVE frames whose batch peak is at least `CaptureBridge.silencePeak`. One nonzero
/// buffer between zeros is not a recovered carrier.
public struct SustainedSignal: Equatable, Sendable {
    public static let rate = 24_000.0
    public private(set) var consecutiveFrames = 0
    /// When the run first reached `takeoverSignal` (nil: not yet since the last reset).
    public private(set) var reachedAt: TimeInterval?

    public init() {}

    /// Adds a batch; returns `now` the first time the consecutive run reaches the threshold.
    public mutating func add(frames: Int, peak: Float, at now: TimeInterval) -> TimeInterval? {
        guard frames > 0 else { return nil }
        if peak >= CaptureBridge.silencePeak { consecutiveFrames += frames } else { consecutiveFrames = 0 }
        guard reachedAt == nil, Double(consecutiveFrames) / Self.rate >= CaptureBridge.takeoverSignal - 0.000_001 else { return nil }
        reachedAt = now
        return now
    }

    public mutating func reset() { self = SustainedSignal() }
}
