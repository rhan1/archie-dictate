import Foundation

/// The AVAudioEngine notification boundary supplies identity/epoch checks and
/// hardware calls. This policy is also exercised without opening audio hardware.
public enum CaptureConfigurationRecovery {
    public enum Result: Equatable { case stale, retapped, rebuilt, failed }
    /// The recorder calls this under its state lock after hardware recovery.
    public static func activate(epoch: CaptureEpoch, current: CaptureEpoch,
                                _ activation: () -> Void) -> Bool {
        guard current === epoch else { return false }
        activation()
        return true
    }
    public static func run(isCurrent: () -> Bool, retap: () throws -> Void,
                           rebuildAndStart: () throws -> Void, teardown: () -> Void,
                           note: (Error) -> Void) -> Result {
        guard isCurrent() else { return .stale }
        do {
            try captureObjC(retap)
            guard isCurrent() else { teardown(); return .stale }
            return .retapped
        } catch { note(error) }
        guard isCurrent() else { teardown(); return .stale }
        do {
            try captureObjC(rebuildAndStart)
            guard isCurrent() else { teardown(); return .stale }
            return .rebuilt
        } catch { note(error); teardown(); return .failed }
    }

    /// Cleanup continues after each individual stop/remove/reset exception.
    @discardableResult public static func teardown(_ calls: [() throws -> Void],
                                                   note: (Error) -> Void) -> Bool {
        var succeeded = true
        for call in calls {
            do { try captureObjC(call) }
            catch { succeeded = false; note(error) }
        }
        return succeeded
    }
}

/// v1.7 H2: one clean restart of the headset engine. coreaudiod re-requests a dropped
/// eSCO link only when the device's IO count falls to zero and a client starts again.
public enum HeadsetRestart {
    public static let idlePoll: TimeInterval = 0.4
    public static let pollStep: TimeInterval = 0.02
    public static let settle: TimeInterval = 0.15
    public struct Outcome: Equatable, Sendable {
        public var waitedMs: Int
        /// The Bluetooth input stopped running everywhere before the start.
        public var deviceIdle: Bool
        public var started: Bool
    }
    /// `isRunningSomewhere` returns nil when the property cannot be read (treated as running).
    public static func perform(stop: () -> Void, isRunningSomewhere: () -> Bool?,
                               sleep: (TimeInterval) -> Void, start: () throws -> Void,
                               note: (Error) -> Void) -> Outcome {
        stop()
        var waited: TimeInterval = 0
        var idle = isRunningSomewhere() == false
        while !idle, waited + pollStep <= idlePoll + 0.000001 {
            sleep(pollStep)
            waited += pollStep
            idle = isRunningSomewhere() == false
        }
        sleep(settle)
        waited += settle
        var started = false
        do { try captureObjC(start); started = true } catch { note(error) }
        return Outcome(waitedMs: Int((waited * 1000).rounded()), deviceIdle: idle, started: started)
    }
}

/// v1.7 H3: the bridge child must stay on the built-in microphone. AVAudioEngine re-binds
/// its input to the system default (the headset aggregate) on a configuration change.
public enum BuiltinPin {
    public enum Check: Equatable, Sendable {
        case ok
        case corrected(from: UInt32)
        case drift(from: UInt32)
        public var note: String {
            switch self {
            case .ok: return "bridge_device_check=ok"
            case .corrected(let from): return "bridge_device_check=drift from=\(from) fixed=1"
            case .drift(let from): return "bridge_device_check=drift from=\(from) fixed=0"
            }
        }
    }
    /// Reads the AUHAL's current device; on drift writes the built-in once and reads back.
    public static func enforce(expected: UInt32, read: () throws -> UInt32,
                               write: (UInt32) throws -> Void) -> Check {
        guard let current = try? read() else { return .drift(from: 0) }
        if current == expected { return .ok }
        guard (try? write(expected)) != nil, let after = try? read(), after == expected else {
            return .drift(from: current)
        }
        return .corrected(from: current)
    }
}

/// v1.7 H4: after a start failure, at most one retap/rebuild within `window`, then the
/// next one waits until `window + backoff` after the failure; requests in between coalesce.
/// HAL `Start failed` is not always thrown to us, so a configuration change arriving
/// within `window` of our previous recovery counts as one too.
public struct RecoveryThrottle: Sendable {
    public static let window: TimeInterval = 1.0
    public static let backoff: TimeInterval = 0.6
    public enum Admission: Equatable, Sendable { case now, after(TimeInterval), coalesced }
    public private(set) var attempts = 0
    private var episodeStart: TimeInterval?
    private var usedInEpisode = 0
    private var lastAttempt: TimeInterval?
    private var pendingAt: TimeInterval?
    public init() {}

    public mutating func startFailed(at time: TimeInterval) {
        if let start = episodeStart, time < start + Self.window + Self.backoff { return }
        episodeStart = time
        usedInEpisode = 0
    }

    public mutating func request(at time: TimeInterval) -> Admission {
        if let pending = pendingAt, time < pending { return .coalesced }
        if let last = lastAttempt, time - last < Self.window, episodeStart.map({ time >= $0 + Self.window + Self.backoff }) ?? true {
            episodeStart = last
            usedInEpisode = 1
        }
        if let start = episodeStart, time < start + Self.window + Self.backoff {
            if time < start + Self.window, usedInEpisode == 0 {
                usedInEpisode = 1
                return attempt(at: time)
            }
            let due = start + Self.window + Self.backoff
            pendingAt = due
            return .after(due - time)
        }
        episodeStart = nil
        return attempt(at: time)
    }

    /// The deferred recovery runs now; its episode is over.
    public mutating func deferredFired(at time: TimeInterval) {
        pendingAt = nil
        episodeStart = nil
        _ = attempt(at: time)
    }

    private mutating func attempt(at time: TimeInterval) -> Admission {
        attempts += 1
        lastAttempt = time
        return .now
    }
}
