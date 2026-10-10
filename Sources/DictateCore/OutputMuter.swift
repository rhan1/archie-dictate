import Foundation

/// Mute flags only. Implementations deliver change callbacks on the same queue
/// as OutputMuter calls (the main queue in production). No volume operations.
public protocol OutputMuteDevice: AnyObject {
    func defaultOutputUID() -> String?
    func isMuted(uid: String) -> Bool?
    func setMuted(_ muted: Bool, uid: String) -> Bool
    func observeChanges(uid: String, _ action: @escaping () -> Void) -> CaptureCancellation?
}

public extension OutputMuteDevice {
    func observeChanges(uid: String, _ action: @escaping () -> Void) -> CaptureCancellation? { nil }
}

/// Owns crash records until restoration is verified and its settle window ends.
/// All calls, clock callbacks and device notifications must be serialized.
public final class OutputMuter {
    public enum Event: String, Sendable {
        case muted, restored = "restored(verified)", unmuteRecovered = "mute_recovered=1"
        case unsupported, none, restoreFailed = "restore_failed", muteReasserted = "mute_reasserted=1"
        public static var restorePending: Event { .restoreFailed }
    }

    private final class State {
        let uid: String
        let prior: Bool
        var deadline: TimeInterval?
        var clean = false
        var timers: [CaptureCancellation] = []
        var observation: CaptureCancellation?
        init(uid: String, prior: Bool) { self.uid = uid; self.prior = prior }
        func cancel() {
            timers.forEach { $0.cancel() }; timers = []
            observation?.cancel(); observation = nil
        }
        deinit { cancel() }
    }

    private let device: OutputMuteDevice
    private let stateFile: URL
    private let clock: CaptureScheduler
    private let settleSeconds: TimeInterval
    private let retryWait: (TimeInterval) -> Void
    private var active: State?
    private var settling: [String: State] = [:]
    public var mutedUID: String? { active?.uid }
    /// Asynchronous settle events; labels contain no device names or content.
    public var onEvent: ((Event) -> Void)?
    public static let defaultStateFile = AppPaths().mutedStateURL

    public init(device: OutputMuteDevice, stateFile: URL = OutputMuter.defaultStateFile,
                clock: CaptureScheduler = CaptureDispatchScheduler(), settleSeconds: TimeInterval = 5,
                retryWait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.device = device; self.stateFile = stateFile; self.clock = clock
        self.settleSeconds = max(0, settleSeconds); self.retryWait = retryWait
    }

    public func mute() -> Event {
        guard active == nil else { return .muted }
        if FileManager.default.fileExists(atPath: stateFile.path),
           recoverIfNeeded() == .restoreFailed { return .restoreFailed }
        guard let uid = device.defaultOutputUID() else { return .none }
        guard let current = device.isMuted(uid: uid) else { return .unsupported }
        let old = settling[uid]
        // A transient profile's true flag during OUR window is not the user's prior.
        let prior = old.flatMap { state in
            state.deadline.map { clock.now <= $0 ? state.prior : current }
        } ?? current
        let state = State(uid: uid, prior: prior)
        // Persist before mutating, including other devices still settling.
        var records = settling
        records[uid] = state
        guard writeState(records) else { return .unsupported }
        old?.cancel(); settling[uid] = nil
        active = state
        guard device.setMuted(true, uid: uid) else {
            // Even a reported failure can have partially written a channel flag.
            return restore() == .restored ? .unsupported : .restoreFailed
        }
        return .muted
    }

    /// Synchronous write/read verification also runs on quit and SIGTERM.
    /// Three retries after the initial attempt, 50 ms apart. Failure retains state.
    @discardableResult
    public func restore() -> Event? {
        guard let state = active else {
            // Quit/SIGTERM can arrive after a normal end but before a profile flip
            // notification. Re-check owned windows synchronously before exit.
            for pending in Array(settling.values) { check(pending) }
            return nil
        }
        guard verifyRestore(state) else { return .restoreFailed }
        active = nil
        beginSettling(state)
        return .restored
    }

    @discardableResult
    public func recoverIfNeeded() -> Event? {
        guard active == nil, settling.values.allSatisfy({ $0.deadline == nil }),
              FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
        guard let text = try? String(contentsOf: stateFile, encoding: .utf8) else { return .restoreFailed }
        var records: [String: State] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1] == "0" || parts[1] == "1" else { return .restoreFailed }
            let uid = String(parts[0])
            guard records[uid] == nil else { return .restoreFailed }
            records[uid] = State(uid: uid, prior: parts[1] == "1")
        }
        guard !records.isEmpty else { return .restoreFailed }
        settling.values.forEach { $0.cancel() }
        settling = records // Keep all records, including any device that disappeared.
        var verified = true
        for state in records.values {
            if verifyRestore(state) { beginSettling(state) }
            else { verified = false }
        }
        return verified ? .unmuteRecovered : .restoreFailed
    }

    private func verifyRestore(_ state: State, until deadline: TimeInterval? = nil) -> Bool {
        for attempt in 0...3 {
            if let deadline, clock.now + (attempt > 0 ? 0.05 : 0) > deadline { return false }
            if attempt > 0 { retryWait(0.05) }
            if let deadline, clock.now > deadline { return false }
            let written = device.setMuted(state.prior, uid: state.uid)
            let readBack = device.isMuted(uid: state.uid)
            if written && readBack == state.prior { return true }
        }
        return false
    }

    private func beginSettling(_ state: State) {
        state.cancel()
        state.clean = true
        state.deadline = clock.now + settleSeconds
        settling[state.uid] = state
        state.observation = device.observeChanges(uid: state.uid) { [weak self, weak state] in
            guard let self, let state else { return }
            self.check(state)
        }
        // Include the exact final boundary even for a custom duration.
        let times = Set([0.5, 1, 2, 3, 5].filter { $0 < settleSeconds } + [settleSeconds]).sorted()
        for delay in times {
            state.timers.append(clock.schedule(after: delay) { [weak self, weak state] in
                guard let self, let state else { return }
                self.check(state, finishing: delay == self.settleSeconds)
            })
        }
    }

    private func check(_ state: State, finishing: Bool = false) {
        guard settling[state.uid] === state, active?.uid != state.uid,
              let deadline = state.deadline else { return }
        // Notifications queued after the window may reflect a deliberate user mute.
        guard clock.now <= deadline else {
            if finishing {
                state.clean = device.isMuted(uid: state.uid) == state.prior
                finish(state)
            }
            return
        }
        let current = device.isMuted(uid: state.uid)
        if current == state.prior {
            state.clean = true
        } else if !state.prior, current == true {
            state.clean = verifyRestore(state, until: deadline)
            onEvent?(state.clean ? .muteReasserted : .restoreFailed)
        } else {
            state.clean = false
            onEvent?(.restoreFailed)
        }
        if finishing { finish(state) }
    }

    private func finish(_ state: State) {
        state.cancel()
        if state.clean {
            settling[state.uid] = nil
            persistRemaining()
        }
        // A dirty window retains its crash record, but has no more callbacks.
    }

    private func persistRemaining() {
        var records = settling
        if let active { records[active.uid] = active }
        if records.isEmpty { try? FileManager.default.removeItem(at: stateFile) }
        else { _ = writeState(records) }
    }

    private func writeState(_ records: [String: State]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = records.keys.sorted().map { uid in "\(uid)\t\(records[uid]!.prior ? 1 : 0)" }.joined(separator: "\n")
            try text.write(to: stateFile, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }
}
