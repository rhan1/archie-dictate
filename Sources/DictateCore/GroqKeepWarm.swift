import Foundation

/// Keeps the Groq HTTPS connection warm after long idle (a 16 h-idle first
/// request paid a fresh DNS + TLS handshake and ran 2x slower). After any
/// dictation activity it pings every `interval` seconds until the app has been
/// idle for `idleCap`; the next activity resumes it. It never pings while a
/// dictation is in flight: that real request warms the connection itself.
/// Clock, sleeper and ping are injected so tests need no network or real time.
public final class GroqKeepWarm: @unchecked Sendable {
    public static let interval: TimeInterval = 240
    public static let idleCap: TimeInterval = 7200

    /// DICTATE_KEEPWARM=0 disables it; anything else (or unset) leaves it on.
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["DICTATE_KEEPWARM"] != "0"
    }

    private let enabled: Bool
    private let interval: TimeInterval
    private let idleCap: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let ping: @Sendable () async -> Void
    private let lock = NSLock()
    private var lastActivity: TimeInterval = 0
    private var busy = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var pingCount = 0

    public init(enabled: Bool = true, interval: TimeInterval = GroqKeepWarm.interval, idleCap: TimeInterval = GroqKeepWarm.idleCap,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                ping: @escaping @Sendable () async -> Void) {
        self.enabled = enabled
        self.interval = interval
        self.idleCap = idleCap
        self.now = now
        self.sleep = sleep
        self.ping = ping
    }

    /// Pings sent so far (diagnostics; counts only).
    public var pings: Int { lock.withLock { pingCount } }

    /// A dictation started or finished: restart the idle clock and the 240 s cadence.
    public func activity() {
        guard enabled else { return }
        lock.withLock {
            lastActivity = now()
            generation += 1
            let mine = generation
            task?.cancel()
            task = Task { [self] in await run(mine) }
        }
    }

    /// True from recording start until the dictation is delivered.
    public func setBusy(_ value: Bool) { lock.withLock { busy = value } }

    public func cancel() {
        lock.withLock {
            generation += 1
            task?.cancel()
            task = nil
        }
    }

    /// Resolves when the current loop has stopped (idle cap, cancel or replaced).
    func waitUntilIdle() async {
        let current = lock.withLock { task }
        await current?.value
    }

    private enum Step { case stop, skip, send }

    private func step(_ mine: Int) -> Step {
        lock.withLock {
            guard generation == mine else { return .stop }
            let t = now()
            if busy { lastActivity = t; return .skip }
            if t - lastActivity >= idleCap { return .stop }
            pingCount += 1
            return .send
        }
    }

    private func run(_ mine: Int) async {
        while true {
            await sleep(interval)
            switch step(mine) {
            case .stop: return
            case .skip: continue
            case .send: await ping()
            }
        }
    }
}
