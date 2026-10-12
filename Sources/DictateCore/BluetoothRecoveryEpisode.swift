import Foundation

/// The four places that can restart the headset engine.
public enum RecoveryPath: String, Sendable {
    /// `MicStartChain`'s retry after a failed start.
    case startRetry = "start_retry"
    /// `CaptureLifecycle`'s first-buffer timeout.
    case firstBuffer = "first_buffer"
    /// An `AVAudioEngineConfigurationChange` (retap/rebuild).
    case configuration
    /// H2: the headset went digital-zero while the built-in carries.
    case restart
}

/// The engine's answer to a lifecycle retry request.
public enum RecoveryAdmission: Equatable, Sendable {
    /// Go ahead, after `after` seconds (0 = now).
    case proceed(after: TimeInterval)
    /// The engine owns recovery for this dictation (the built-in carries); do not retry here.
    case skip
}

/// v1.8 (L3): one Bluetooth recovery policy for the whole dictation, surviving engine
/// replacements. It applies only when the default input is Bluetooth; every other input keeps
/// today's prompt recovery (`bluetooth == false` admits everything at once).
///
/// One controlled restart per `window`; a restart begins only after the input format has been
/// stable for `stableFor` (that debounce is bounded by the window, so a notification storm
/// cannot defer it forever). A restart succeeds when frames arrive within `successWithin`,
/// not when `start()` returns. Configuration notifications only record state.
///
/// v1.9 (L1): when the configuration notification finds the engine already stopped (AVAudioEngine
/// auto-stopped it on the A2DP→HFP switch), the episode's FIRST attempt is immediate: the idle
/// SCO route is torn down ~250 ms after it connects unless a client is doing IO (10-13 01:53:08:
/// connected .501, our notification .542, "Sco route is disabled" .755; v1.8's 200 ms debounce
/// put IO back only at .876). Every later attempt keeps the debounce and the window.
public struct BluetoothRecoveryEpisode: Sendable {
    public static let window: TimeInterval = 1.5
    public static let stableFor: TimeInterval = 0.2
    public static let successWithin: TimeInterval = 1.0
    /// Observed teardown 159 ms (21:33) plus stop latency.
    public static let settleAfterStop: TimeInterval = 0.3
    /// At most this many admitted restarts per dictation (decision D8; no spin).
    public static let maxAttempts = 3

    public enum Admission: Equatable, Sendable {
        case now
        case after(TimeInterval)
        /// A restart is already queued; this request is folded into it.
        case coalesced
        /// No more attempts this dictation (budget spent, or external busy twice).
        case exhausted
    }
    public enum Outcome: String, Sendable {
        /// `silentFrames` (v1.9): buffers arrived, but all digital zeros (an idle SCO route
        /// injects silence) — not a recovered headset; the episode treats it like `noFrames`.
        case frames, silentFrames = "silent_frames", noFrames = "no_frames", skipped, failed, externalBusy = "external_busy"
    }

    /// v1.9 (L1): an attempt succeeded only if a buffer with signal (peak ≥
    /// `CaptureBridge.silencePeak`) arrived within `successWithin` of `since`; zeros never count.
    public static func verdict(since: TimeInterval, firstFrame: TimeInterval?, firstSignal: TimeInterval?) -> Outcome {
        if let firstSignal, firstSignal <= since + successWithin { return .frames }
        if let firstFrame, firstFrame <= since + successWithin { return .silentFrames }
        return .noFrames
    }

    public let bluetooth: Bool
    public private(set) var attempts = 0
    public private(set) var requests = 0
    public private(set) var outcomes: [Outcome] = []
    public private(set) var externalBusySeen = false
    /// v1.9: first attempts admitted without the debounce (engine auto-stopped).
    public private(set) var immediateAttempts = 0
    private var attemptsAfterBusy = 0
    private var windowStart: TimeInterval?
    private var usedInWindow = false
    private var lastFormatChange: TimeInterval?
    /// The queued attempt's due time (nil: none queued).
    public private(set) var pendingDue: TimeInterval?
    private var running = false

    public init(bluetooth: Bool) { self.bluetooth = bluetooth }

    /// A configuration notification: recorded, never acted on directly.
    public mutating func formatChanged(at time: TimeInterval) { lastFormatChange = time }

    /// `engineStopped` (v1.9): a configuration notification found the headset engine no longer
    /// running; the episode's first attempt is then admitted now, without the debounce.
    public mutating func request(_ path: RecoveryPath, at now: TimeInterval, engineStopped: Bool = false) -> Admission {
        requests += 1
        guard bluetooth else { attempts += 1; return .now }
        if pendingDue != nil || running { return .coalesced }
        if attempts >= Self.maxAttempts || (externalBusySeen && attemptsAfterBusy >= 1) { return .exhausted }
        if path == .configuration, engineStopped, attempts == 0, windowStart == nil {
            immediateAttempts += 1
            windowStart = now
            pendingDue = now
            return .now
        }
        if let start = windowStart, now >= start + Self.window { windowStart = nil; usedInWindow = false }
        let stable = lastFormatChange.map { $0 + Self.stableFor } ?? now
        let due: TimeInterval
        if let start = windowStart, usedInWindow {
            // This window's restart is spent: the next window opens at its end.
            let next = start + Self.window
            due = min(max(next, stable), next + Self.window)
        } else {
            let start = windowStart ?? now
            windowStart = start
            due = min(max(now, stable), start + Self.window)
        }
        pendingDue = due
        return due <= now ? .now : .after(due - now)
    }

    /// The queued (or immediate) attempt runs now. Returns false when it must not (it was
    /// already settled, or the debounce moved: a later format change re-queues it).
    /// `force`: the caller already waited the admitted delay itself (a lifecycle retry).
    public mutating func begin(at now: TimeInterval, force: Bool = false) -> Bool {
        guard bluetooth else { return true }
        guard let due = pendingDue, force || now >= due - 0.001 else { return false }
        pendingDue = nil
        if windowStart == nil || now >= windowStart! + Self.window { windowStart = now; usedInWindow = false }
        usedInWindow = true
        running = true
        attempts += 1
        if externalBusySeen { attemptsAfterBusy += 1 }
        return true
    }

    public enum Begin: Equatable, Sendable { case begun, notPending, wait(TimeInterval) }
    /// A queued attempt is due: re-checks the stable-format debounce (a later notification moved
    /// it, bounded by the window) and either begins or tells the caller to requeue.
    public mutating func beginIfStable(at now: TimeInterval) -> Begin {
        guard bluetooth else { return .begun }
        guard let due = pendingDue else { return .notPending }
        var stable = max(due, lastFormatChange.map { $0 + Self.stableFor } ?? due)
        if let start = windowStart { stable = min(stable, max(due, start + Self.window)) }
        if now < stable - 0.001 {
            pendingDue = stable
            return .wait(stable - now)
        }
        return begin(at: now) ? .begun : .notPending
    }

    /// The queued attempt is no longer needed (healthy signal, replaced engine, new epoch):
    /// it settles as `skipped` without spending an attempt.
    public mutating func skip() {
        guard pendingDue != nil else { return }
        pendingDue = nil
        outcomes.append(.skipped)
    }

    public mutating func settled(_ outcome: Outcome) {
        running = false
        if outcome == .externalBusy { externalBusySeen = true }
        outcomes.append(outcome)
    }

    public var isRunning: Bool { running }
    public var lastOutcome: Outcome? { outcomes.last }
}

/// v1.8 (L1): idempotent teardown of a unit we own: stop → uninitialize → dispose, each
/// attempted once even when an earlier one fails, also after a partial start.
public struct OwnedUnitTeardown: Sendable {
    public private(set) var created = false
    public private(set) var disposed = false
    public init() {}
    public mutating func didCreate() { created = true; disposed = false }

    /// Returns the failures (empty = clean). A second call does nothing.
    @discardableResult
    public mutating func run(stop: () throws -> Void, uninitialize: () throws -> Void,
                             dispose: () throws -> Void) -> [Error] {
        guard created, !disposed else { return [] }
        disposed = true
        var errors: [Error] = []
        do { try captureObjC { try stop() } } catch { errors.append(error) }
        do { try captureObjC { try uninitialize() } } catch { errors.append(error) }
        do { try captureObjC { try dispose() } } catch { errors.append(error) }
        return errors
    }
}
