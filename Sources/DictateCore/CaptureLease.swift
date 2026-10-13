import Foundation

/// v1.12 (L1): one session-scoped capture lease per process (GPT-6 review §A, rank 4).
///
/// The lease is what may own the microphone: the headset client, built-in continuity, the frame
/// timeline, the recovery episode, mute ownership and — the part v1.11 lacked — RELEASE
/// COMPLETION. `AudioRecorder.stop()` still returns the captured samples at once, but the lease
/// stays `releasing` until every hardware part it started (built-in unit, headset client) has
/// acknowledged its teardown. A new request (⌥⌥ or ⌘⌘, any host, any recorder instance in the
/// process) is admitted exactly once per completed release:
///
/// - no lease → granted now;
/// - an ACTIVE lease → refused `busy` (one owner; the host maps it to `prestart_skipped=…`);
/// - a RELEASING lease → the request waits (up to `releaseWait`) and the first waiter is granted
///   when the release completes; later waiters are refused `busy` (the first one owns it now);
/// - a release that never completes is QUARANTINED after `quarantineAfter`: it is never reused
///   and its late callbacks stay rejected (their token is not current), and the next request is
///   admitted with `quarantined_prev=1` on its line, instead of blocking capture until relaunch.
///
/// Every frame callback carries the token of the lease that started its hardware; `admits(_:)`
/// is false for any other token, so a cancelled/late callback of an old lease can never append
/// to a newer session.
public final class CaptureLeaseBroker: @unchecked Sendable {
    public static let shared = CaptureLeaseBroker()
    /// How long a request waits for a pending release before it is refused `releasePending`.
    public static let releaseWait: TimeInterval = 2.0
    /// A release still pending this long after it began is quarantined.
    public static let quarantineAfter: TimeInterval = 4.0

    public enum Kind: String, Sendable { case dictation, conversation }
    public enum Refusal: Error, Equatable, Sendable {
        /// Another lease is live (or a waiter was admitted first).
        case busy(holder: Kind)
        /// The previous lease's hardware release did not complete within `releaseWait`.
        case releasePending(holder: Kind)

        /// `lease_refused=busy holder=conversation`.
        public var note: String {
            switch self {
            case .busy(let holder): return "lease_refused=busy holder=\(holder.rawValue)"
            case .releasePending(let holder): return "lease_refused=release_pending holder=\(holder.rawValue)"
            }
        }
    }
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let schedule: Scheduler
    private var current: CaptureLease?
    private struct Waiter {
        let id: Int
        let kind: Kind
        let since: TimeInterval
        let completion: @Sendable (Result<CaptureLease, Refusal>) -> Void
    }
    private var waiters: [Waiter] = []
    private var nextWaiter = 0
    private var serial = 0
    /// Leases granted, releases completed, leases quarantined (counts for tests and notes).
    public private(set) var granted = 0
    public private(set) var releasesCompleted = 0
    public private(set) var quarantined = 0

    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                schedule: @escaping Scheduler = { delay, work in
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
                }) {
        self.clock = clock
        self.schedule = schedule
    }

    /// The live or releasing lease (nil: the microphone is free).
    public var holder: CaptureLease? { lock.withLock { current } }

    /// Request a lease. `completion` runs exactly once: at once (granted / busy), or when the
    /// pending release completes or `wait` elapses. Never called under the broker's lock.
    public func request(_ kind: Kind, wait: TimeInterval = CaptureLeaseBroker.releaseWait,
                        completion: @escaping @Sendable (Result<CaptureLease, Refusal>) -> Void) {
        let now = clock()
        var immediate: Result<CaptureLease, Refusal>?
        var waiterID: Int?
        var quarantineCheck: TimeInterval?
        lock.withLock {
            quarantineIfOverdueLocked(at: now)
            guard let lease = current else { immediate = .success(grantLocked(kind, at: now, waited: 0)); return }
            switch lease.stateLocked {
            case .active:
                immediate = .failure(.busy(holder: lease.kind))
            case .releasing(let since):
                guard wait > 0 else { immediate = .failure(.releasePending(holder: lease.kind)); return }
                nextWaiter += 1
                waiterID = nextWaiter
                waiters.append(Waiter(id: nextWaiter, kind: kind, since: now, completion: completion))
                quarantineCheck = max(0, since + Self.quarantineAfter - now)
            case .released, .quarantined:
                current = nil
                immediate = .success(grantLocked(kind, at: now, waited: 0))
            }
        }
        drainNotifications()
        if let immediate { completion(immediate); return }
        guard let waiterID else { return }
        schedule(wait) { [weak self] in self?.expire(waiterID) }
        // A release that is already overdue relative to the waiter's deadline is quarantined then.
        if let check = quarantineCheck, check < wait {
            schedule(check) { [weak self] in self?.quarantineIfOverdue() }
        }
    }

    /// Swift-concurrency form of `request`.
    public func acquire(_ kind: Kind, wait: TimeInterval = CaptureLeaseBroker.releaseWait) async -> Result<CaptureLease, Refusal> {
        await withCheckedContinuation { continuation in
            request(kind, wait: wait) { continuation.resume(returning: $0) }
        }
    }

    /// No waiting: granted now, or refused.
    public func tryAcquire(_ kind: Kind) -> Result<CaptureLease, Refusal> {
        let box = ResultBox()
        request(kind, wait: 0) { box.value = $0 }
        return box.value ?? .failure(.busy(holder: kind))
    }

    private final class ResultBox: @unchecked Sendable { var value: Result<CaptureLease, Refusal>? }

    private func grantLocked(_ kind: Kind, at now: TimeInterval, waited: TimeInterval) -> CaptureLease {
        serial += 1
        granted += 1
        let note = quarantinedPending
        quarantinedPending = false
        let lease = CaptureLease(broker: self, kind: kind, serial: serial, grantedAt: now,
                                 waitedMs: Int((waited * 1000).rounded()), afterQuarantine: note)
        current = lease
        return lease
    }
    private var quarantinedPending = false

    private func expire(_ id: Int) {
        let expired: Waiter? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index)
        }
        guard let expired else { return }
        quarantineIfOverdue()
        // The quarantine may have freed the microphone for this very waiter.
        let now = clock()
        let result: Result<CaptureLease, Refusal> = lock.withLock {
            if let lease = current {
                switch lease.stateLocked {
                case .active: return .failure(.busy(holder: lease.kind))
                case .releasing: return .failure(.releasePending(holder: lease.kind))
                case .released, .quarantined: current = nil
                }
            }
            return .success(grantLocked(expired.kind, at: now, waited: now - expired.since))
        }
        expired.completion(result)
    }

    private func quarantineIfOverdue() {
        let now = clock()
        let admitted = lock.withLock { () -> (Waiter, CaptureLease)? in
            quarantineIfOverdueLocked(at: now)
            return admitFirstWaiterLocked(at: now)
        }
        drainNotifications()
        flush(admitted)
    }

    private func quarantineIfOverdueLocked(at now: TimeInterval) {
        guard let lease = current, case .releasing(let since) = lease.stateLocked,
              now >= since + Self.quarantineAfter - 0.000_001 else { return }
        lease.stateLocked = .quarantined
        notifications += lease.takeSettledLocked(.quarantined)
        quarantined += 1
        quarantinedPending = true
        current = nil
    }

    /// The lease's last hardware part acknowledged release.
    fileprivate func released(_ lease: CaptureLease) {
        let now = clock()
        let admitted = lock.withLock { () -> (Waiter, CaptureLease)? in
            guard current === lease else { return nil }      // a quarantined lease finishing late
            releasesCompleted += 1
            current = nil
            return admitFirstWaiterLocked(at: now)
        }
        flush(admitted)
    }

    /// Exactly one waiter is admitted per freed microphone; the rest are refused `busy`.
    private func admitFirstWaiterLocked(at now: TimeInterval) -> (Waiter, CaptureLease)? {
        guard current == nil, !waiters.isEmpty else { return nil }
        let first = waiters.removeFirst()
        let lease = grantLocked(first.kind, at: now, waited: now - first.since)
        return (first, lease)
    }

    private func flush(_ admitted: (Waiter, CaptureLease)?) {
        guard let (waiter, lease) = admitted else { return }
        let refused: [Waiter] = lock.withLock {
            defer { waiters.removeAll() }
            return waiters
        }
        waiter.completion(.success(lease))
        for other in refused { other.completion(.failure(.busy(holder: lease.kind))) }
    }

    fileprivate func withLock<T>(_ body: () -> T) -> T { lock.withLock(body) }
    fileprivate func now() -> TimeInterval { clock() }

    /// Settle callbacks of a quarantined lease, collected under the lock and run after it.
    private var notifications: [@Sendable () -> Void] = []
    private func drainNotifications() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            defer { notifications.removeAll() }
            return notifications
        }
        pending.forEach { $0() }
    }
}

/// One owner's hold on the microphone, from grant to acknowledged hardware release.
public final class CaptureLease: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case active
        /// `release()` ran at `since`; parts are still tearing down.
        case releasing(since: TimeInterval)
        case released
        /// The release never completed; the lease is dead and never reused.
        case quarantined
    }
    /// The hardware a lease starts; each acknowledges its own teardown.
    public enum Part: String, Sendable, CaseIterable { case builtin, headset }

    public let kind: CaptureLeaseBroker.Kind
    public let serial: Int
    /// Frames and callbacks carry this token; only the current lease's token is admitted.
    public let token = CaptureEpoch()
    public let grantedAt: TimeInterval
    /// How long the request waited for a previous release (0: granted at once).
    public let waitedMs: Int
    /// The previous lease was quarantined (its release never completed).
    public let afterQuarantine: Bool
    // Strong: a late part acknowledgement may outlive every other reference to the broker (the
    // broker holds a lease only while it is current, so the cycle ends at release).
    private let broker: CaptureLeaseBroker
    fileprivate var stateLocked: State = .active
    private var started: Set<Part> = []
    private var pending: Set<Part> = []
    private var mute = false
    private var releaseBegan: TimeInterval?
    private var releaseDone: TimeInterval?
    private var onSettled: [@Sendable (State) -> Void] = []

    fileprivate init(broker: CaptureLeaseBroker, kind: CaptureLeaseBroker.Kind, serial: Int,
                     grantedAt: TimeInterval, waitedMs: Int, afterQuarantine: Bool) {
        self.broker = broker
        self.kind = kind
        self.serial = serial
        self.grantedAt = grantedAt
        self.waitedMs = waitedMs
        self.afterQuarantine = afterQuarantine
    }

    public var state: State { broker.withLock { stateLocked } }
    public var isActive: Bool { state == .active }

    /// A frame/callback stamped with `token` may enter this lease's session.
    public func admits(_ token: CaptureEpoch) -> Bool {
        broker.withLock { stateLocked == .active && token === self.token }
    }

    /// The owner started (or is starting) a hardware part: release waits for its acknowledgement.
    /// False after release began (the caller must not start hardware for a dead lease).
    @discardableResult public func started(_ part: Part) -> Bool {
        broker.withLock {
            guard stateLocked == .active else { return false }
            started.insert(part)
            return true
        }
    }

    /// Only the active lease may hold the media mute; it is relinquished by `release()`.
    public func claimMute() -> Bool {
        broker.withLock {
            guard stateLocked == .active else { return false }
            mute = true
            return true
        }
    }
    public var ownsMute: Bool { broker.withLock { mute && stateLocked == .active } }

    /// Begin release at `now`: every started part must acknowledge. With none started the
    /// release completes at once. Idempotent.
    public func release(at time: TimeInterval? = nil) {
        let now = time ?? broker.now()
        let done: Bool = broker.withLock {
            guard stateLocked == .active else { return false }
            mute = false
            releaseBegan = now
            pending = started
            stateLocked = .releasing(since: now)
            if pending.isEmpty { stateLocked = .released; releaseDone = now; return true }
            return false
        }
        if done { finish() }
    }

    /// A part finished its teardown. The last one completes the release and admits the next lease.
    public func partReleased(_ part: Part, at time: TimeInterval? = nil) {
        let now = time ?? broker.now()
        let done: Bool = broker.withLock {
            guard case .releasing = stateLocked, pending.remove(part) != nil, pending.isEmpty else { return false }
            stateLocked = .released
            releaseDone = now
            return true
        }
        if done { finish() }
    }

    private func finish() {
        let callbacks = broker.withLock { takeSettledLocked(.released) }
        broker.released(self)
        callbacks.forEach { $0() }
    }

    /// Caller holds the broker lock: the settle callbacks, bound to `state`, to run after it.
    fileprivate func takeSettledLocked(_ state: State) -> [@Sendable () -> Void] {
        defer { onSettled.removeAll() }
        return onSettled.map { body in { body(state) } }
    }

    /// Runs once the release settled — `.released` (hardware acknowledged) or `.quarantined`
    /// (it never did) — at once if it already has. Never under a lock.
    public func whenSettled(_ body: @escaping @Sendable (State) -> Void) {
        let settled: State? = broker.withLock {
            if stateLocked == .released || stateLocked == .quarantined { return stateLocked }
            onSettled.append(body)
            return nil
        }
        if let settled { body(settled) }
    }

    /// Awaits the release's settlement (`.released` or `.quarantined`).
    public func settled() async -> State {
        await withCheckedContinuation { (continuation: CheckedContinuation<State, Never>) in
            whenSettled { continuation.resume(returning: $0) }
        }
    }

    /// Parts still tearing down (empty when active or released).
    public var pendingParts: Set<Part> { broker.withLock { pending } }

    /// The session line's part: `lease=3 lease_kind=dictation lease_wait_ms=0` (+ ` quarantined_prev=1`).
    public var grantNote: String {
        "lease=\(serial) lease_kind=\(kind.rawValue) lease_wait_ms=\(waitedMs)" + (afterQuarantine ? " quarantined_prev=1" : "")
    }

    /// `lease=3 lease_kind=dictation lease_wait_ms=0 release_ms=41` (+ ` quarantined_prev=1`).
    /// `release_ms=-` until the release completed.
    public var note: String {
        broker.withLock {
            let releaseMs = zip(releaseBegan, releaseDone).map { "\(max(0, Int((($1 - $0) * 1000).rounded())))" } ?? "-"
            return "lease=\(serial) lease_kind=\(kind.rawValue) lease_wait_ms=\(waitedMs) release_ms=\(releaseMs)"
                + (afterQuarantine ? " quarantined_prev=1" : "")
        }
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
