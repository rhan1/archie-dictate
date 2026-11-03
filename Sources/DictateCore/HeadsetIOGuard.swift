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
/// - An open obligation gets ONE re-attach as soon as none is in flight. A re-attach is IN FLIGHT
///   from its start until fresh headset frames arrive (IO completed), its start fails, or
///   `inFlightBound` passes without frames. Nothing else touches the engine while one is in
///   flight (that keeps v1.10's protection against churn while the SCO link forms), but the
///   bound is a ceiling, not a blind wait: observed frames end it early.
/// - If that re-attach brought no IO, the obligation ESCALATES once to the episode's restart
///   (its own budget and debounce) and stays open — visible as `io_obligation=open:…` — until IO
///   is observed. At most `maxReattaches` re-attaches per dictation: bounded, never a spin.
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
    /// v1.28 (B1): HFP found at a start counts as a warm route only when the link has been up this long —
    /// known as the time since this recorder's previous Bluetooth capture released (the route probe samples
    /// the profile, not since when). Inside it the voice link is the previous dictation's, collapsing back to
    /// A2DP (f243a0c8: released 100 ms before the start, `bt_after3s=a2dp` ~1.0 s later).
    public static let warmAfter: TimeInterval = 2.0
    /// v1.28 (B1): an escalated obligation belongs to the episode's restart for at most this long when no
    /// restart ever starts (refused, coalesced away, skipped): then it is owed a re-attach again. The episode's
    /// worst-case admission (its window twice) plus one verification.
    public static let restartWait: TimeInterval = 2 * BluetoothRecoveryEpisode.window + BluetoothRecoveryEpisode.successWithin

    /// v1.28 (B1): what the start found on a Bluetooth input.
    public enum StartRoute: String, Sendable {
        /// Not on HFP (A2DP or unknown): the v1.12 cold path.
        case cold
        /// On HFP for at least `warmAfter` (or no capture of ours released it this launch): v1.13's warm route.
        case warm
        /// On HFP less than `warmAfter` after our previous capture released: cold-on-HFP — the built-in carries
        /// from the first frame, the headset takes over only after `CaptureBridge.takeoverSignal` of signal, and
        /// the guard's obligations keep `engine_stopped` semantics.
        case transient
    }
    /// v1.28 (B1): `hfp` = the route probe found HFP; `sinceRelease` = seconds since this recorder's previous
    /// Bluetooth capture released (nil: none this launch).
    public static func startRoute(hfp: Bool, sinceRelease: TimeInterval?) -> StartRoute {
        guard hfp else { return .cold }
        if let since = sinceRelease, since < warmAfter { return .transient }
        return .warm
    }

    public enum Reaction: Equatable, Sendable {
        /// Re-attach now (the obligation's one in-flight re-attach).
        case reattach
        /// The engine runs and recovery is unsettled: leave it alone.
        case leaveRunning
        /// A re-attach is in flight until `until` at the latest; the obligation stays open and is
        /// re-evaluated on the next observation.
        case pending(until: TimeInterval)
        /// The obligation's re-attach brought no IO: ask the episode for one restart (once).
        case escalate
        /// The re-attach budget is spent; the obligation stays open (the episode decides).
        case exhausted
        /// Not Bluetooth, or no recovery open: the episode's policy decides (v1.9).
        case episode
        /// Nothing to do (an observation found IO healthy or nothing owed).
        case none
    }

    public struct Obligation: Equatable, Sendable {
        public enum Reason: String, Sendable {
            case engineStopped = "engine_stopped", ioCeased = "io_ceased"
            /// v1.13 (L2): a format change on a warm HFP route — discharged only by sustained signal.
            case formatChanged = "format_changed"
        }
        public var since: TimeInterval
        public var reason: Reason
        /// Its one re-attach was given; then its one escalation.
        public var reattached = false
        public var escalated = false
    }

    public let bluetooth: Bool
    /// v1.13 (L2): the headset was already on HFP when this dictation configured its capture (its
    /// voice link was up before our client started). E4/W2 (10-13 15:24, engine arm): the engine's
    /// own start drew a configuration notification at +113/+116 ms while it ran; v1.12 left a running
    /// engine alone, its tap delivered digital zeros, and only the zero-run restart chain (0.7 s of
    /// zeros + 300 ms settle → restart `result=no_frames` after 1.0 s → obligation re-attach) brought
    /// signal — `carrier=builtin:0-2431` on both, identical to the ms. On a warm route there is no voice
    /// link forming for hands-off to protect, so that notification is IO evidence: an obligation opens
    /// and gets its one re-attach at once, discharged only by sustained signal (else it escalates).
    public let warmRoute: Bool
    /// v1.28 (B1): HFP at the start, up less than `warmAfter` (`StartRoute.transient`). Obligations open and are
    /// labelled exactly as on a cold route (`engine_stopped`, never `format_changed`), but the link is known to be
    /// collapsing: digital zeros from a re-attached client are not IO back — only sustained signal ends its
    /// re-attach early or discharges the obligation (zeros keep it owed, so it escalates to the restart, the one
    /// operation that re-requests HFP; f243a0c8 `settled … silent_frames` → `escalate`).
    public let transientRoute: Bool
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
    /// v1.28 (B1): obligations closed because the episode's restart replaced the engine they were owed to
    /// (each later stop of the fresh engine opens a new one). Shown as `io_generation=` when non-zero.
    public private(set) var obligationGeneration = 0
    /// v1.28 (B1): when the current obligation escalated (nil: it did not).
    private var escalatedAt: TimeInterval?
    /// v1.28 FR1-A: what the episode answered the current escalation's restart request.
    public enum RestartAnswer: String, Sendable {
        /// Admitted (now or after its debounce): the restart will run.
        case queued
        /// Folded into a restart that is already running / being verified.
        case started
        /// Folded into a RE-ATTACH's verification still running (the guard's bound expired first): nothing will
        /// restart — the escalation is retained and re-offered once that verification settles.
        case coalesced
        /// The episode's budget is spent.
        case refused
    }
    public private(set) var restartAnswer: RestartAnswer?
    /// FR1-A: the verification a `.coalesced` escalation waited for has settled: `.escalate` is offered again.
    private var escalationReoffer = false
    /// v1.28 (B1): the episode refused this obligation's re-attach for good (its budget is spent): `.exhausted`.
    private var episodeSpent = false
    /// v1.28 (B1): sustained signal since the current obligation opened (`transientRoute` discharges on it).
    private var obligationSignal = SustainedSignal()
    private var obligationSignalled = false

    public init(bluetooth: Bool, warmRoute: Bool = false, transientRoute: Bool = false) {
        self.bluetooth = bluetooth
        self.warmRoute = bluetooth && warmRoute
        self.transientRoute = bluetooth && transientRoute && !warmRoute
    }

    /// v1.28 (B1): what ends a re-attach early / discharges the obligation once the engine runs and frames came.
    private var ioBack: Bool {
        if obligation?.reason == .formatChanged { return settled }
        return !transientRoute || obligationSignalled
    }

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
        if obligation != nil {
            // A warm running engine's new format generation is discharged only by signal (review #7).
            if warmRoute, obligation?.reason == .engineStopped { obligation?.reason = .formatChanged }
            return due(at: now)
        }
        if warmRoute, inFlightSince == nil {
            open(.formatChanged, at: now)
            return due(at: now)
        }
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
            // A warm route's format-change re-attach is over only when signal is back (zeros were the fault).
            if engineRunning, let frame = lastHeadsetFrame, frame > since, ioBack {
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
        if engineRunning, obligation?.reason == .formatChanged, settled {
            discharge()
            return .none
        }
        if engineRunning, obligation?.reason == .engineStopped, let frame = lastHeadsetFrame,
           frame > (obligation?.since ?? .infinity), ioBack {
            discharge()                            // IO came back on its own
            return .none
        }
        return due(at: now)
    }

    /// Headset frames reached the recorder at `now` (`peak`: the batch's largest |sample|).
    public mutating func headsetFrames(_ count: Int, peak: Float, at now: TimeInterval) {
        lastHeadsetFrame = now
        if sustained.add(frames: count, peak: peak, at: now) != nil { settled = true; settledOnce = true }
        if obligation != nil || inFlightSince != nil, obligationSignal.add(frames: count, peak: peak, at: now) != nil {
            obligationSignalled = true
        }
    }

    /// The caller could not perform the `.reattach` it was given (the episode is still verifying an
    /// attempt): un-reserve it; the obligation stays open and is due again on the next observation.
    public mutating func reattachDeclined() {
        guard inFlightSince != nil, reattaches > 0 else { return }
        reattaches -= 1
        inFlightSince = nil
        obligation?.reattached = false
        held += 1
    }

    /// The caller could not perform the `.reattach` because the episode's budget is spent: the
    /// obligation is terminal for the guard (no re-attach, no escalation — the episode said no)
    /// and stays open and visible. Without this a declined re-attach was re-offered every tick.
    public mutating func reattachUnavailable() {
        guard inFlightSince != nil, reattaches > 0 else { return }
        reattaches -= 1
        inFlightSince = nil
        obligation?.reattached = true
        obligation?.escalated = true
        episodeSpent = true
        held += 1
    }

    /// v1.28 FR1-A: the recorder asked the episode for the escalation's restart and got `answer`. A `.coalesced`
    /// answer (a re-attach verification still running) is retained: `attemptSettled()` re-offers `.escalate`
    /// without reserving a re-attach (no episode attempt is spent until the restart begins). `.refused` makes the
    /// obligation `.exhausted`. Ignored unless an escalated obligation is open.
    public mutating func restartRequested(_ answer: RestartAnswer) {
        guard bluetooth, obligation?.escalated == true, !episodeSpent else { return }
        if answer == .refused { episodeSpent = true; restartAnswer = nil; return }
        restartAnswer = answer
        escalationReoffer = false
    }

    /// v1.28 FR1-A: an attempt's verification settled (any verdict): a coalesced escalation is due again.
    public mutating func attemptSettled() {
        if restartAnswer == .coalesced { escalationReoffer = true }
    }

    /// v1.28 (B1): the episode's restart put a fresh engine on the headset (its start returned at `now`). The
    /// escalated obligation it answered is closed — it was owed to an engine that no longer exists — and the
    /// restart is in flight like a re-attach (bounded by `inFlightBound`, ended early by IO). A stop of the fresh
    /// engine opens a NEW obligation with its own re-attach, still within `maxReattaches` and the episode's
    /// `maxAttempts` (f243a0c8: `headset_restart=1` +3402, the fresh engine stopped +3654 and was owed nothing).
    /// No-op when no escalated obligation is open (a bridge zero-run restart owes the guard nothing).
    public mutating func restarted(at now: TimeInterval) {
        guard bluetooth, let open = obligation, open.reattached, open.escalated, !episodeSpent else { return }
        discharge()
        obligationGeneration += 1
        inFlightSince = now
        restartAnswer = nil
        escalationReoffer = false
        obligationSignal.reset()
        obligationSignalled = false
    }

    /// The in-flight re-attach's start returned (`started == false`: it threw — the obligation
    /// escalates on the next observation).
    public mutating func reattachFinished(started: Bool, at now: TimeInterval) {
        if !started { inFlightSince = nil }
    }

    // MARK: Decisions

    private mutating func open(_ reason: Obligation.Reason, at now: TimeInterval) {
        guard obligation == nil else { return }
        obligation = Obligation(since: now, reason: reason)
        obligationsOpened += 1
        escalatedAt = nil
        episodeSpent = false
        restartAnswer = nil
        escalationReoffer = false
        obligationSignal.reset()
        obligationSignalled = false
    }

    private mutating func discharge() {
        guard obligation != nil else { return }
        obligation = nil
        obligationsDischarged += 1
    }

    private mutating func due(at now: TimeInterval) -> Reaction {
        guard let open = obligation else { return .none }
        if let since = inFlightSince, now < since + Self.inFlightBound {
            held += 1
            return .pending(until: since + Self.inFlightBound)
        }
        if episodeSpent { return .exhausted }                // the episode can admit nothing more
        if open.reattached {
            if !open.escalated {
                obligation?.escalated = true
                escalatedAt = now
                return .escalate
            }
            // v1.28 FR1-A: the restart request was folded into a re-attach verification that has now settled:
            // ask for the restart again (no re-attach reserved, no episode attempt spent).
            if restartAnswer == .coalesced, escalationReoffer {
                escalationReoffer = false
                restartAnswer = nil
                escalatedAt = now
                return .escalate
            }
            // v1.28 (B1): the episode's restart owns it only while that restart can still come; it never owes
            // nothing for ever. (Once the restart starts, `restarted(at:)` closes this obligation.)
            if let at = escalatedAt, now < at + Self.restartWait { return .none }
            obligation?.reattached = false                   // no restart came: owed a re-attach again
            obligation?.escalated = false
            escalatedAt = nil
            restartAnswer = nil
            escalationReoffer = false
            obligationGeneration += 1
        }
        guard reattaches < Self.maxReattaches else { return .exhausted }
        reattaches += 1
        obligation?.reattached = true
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
            + (obligationGeneration > 0 ? " io_generation=\(obligationGeneration)" : "")
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
