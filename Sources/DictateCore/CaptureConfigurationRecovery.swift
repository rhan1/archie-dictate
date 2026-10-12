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
///
/// v1.8 (L3): `kAudioDevicePropertyDeviceIsRunningSomewhere` is system-wide, so it is polled
/// only on the intended headset device and only after `stop` has stopped every IO unit we own;
/// still running then means another client (Chrome on 10-12) holds it: `externalBusy`. With
/// `startWhenBusy == false` (a healthy built-in carries) nothing is started into a busy link.
/// Settle is 300 ms: the observed teardown took 159 ms plus stop latency.
public enum HeadsetRestart {
    public static let idlePoll: TimeInterval = 0.4
    public static let pollStep: TimeInterval = 0.02
    public static let settle: TimeInterval = BluetoothRecoveryEpisode.settleAfterStop
    public struct Outcome: Equatable, Sendable {
        public var waitedMs: Int
        /// The Bluetooth input stopped running everywhere before the start.
        public var deviceIdle: Bool
        public var started: Bool
        /// Our units were stopped and the device still ran: another client holds it.
        public var externalBusy = false
        public init(waitedMs: Int, deviceIdle: Bool, started: Bool, externalBusy: Bool = false) {
            self.waitedMs = waitedMs; self.deviceIdle = deviceIdle; self.started = started
            self.externalBusy = externalBusy
        }
    }
    /// `isRunningSomewhere` returns nil when the property cannot be read (treated as running).
    /// `stop` returns whether every owned IO unit is confirmed stopped (false: no busy verdict).
    public static func perform(stop: () -> Bool, isRunningSomewhere: () -> Bool?,
                               sleep: (TimeInterval) -> Void, start: () throws -> Void,
                               startWhenBusy: Bool = true, note: (Error) -> Void) -> Outcome {
        let ownStopped = stop()
        var waited: TimeInterval = 0
        var idle = isRunningSomewhere() == false
        while !idle, waited + pollStep <= idlePoll + 0.000001 {
            sleep(pollStep)
            waited += pollStep
            idle = isRunningSomewhere() == false
        }
        sleep(settle)
        waited += settle
        let busy = ownStopped && !idle && isRunningSomewhere() == true
        var started = false
        if !busy || startWhenBusy {
            do { try captureObjC(start); started = true } catch { note(error) }
        }
        return Outcome(waitedMs: Int((waited * 1000).rounded()), deviceIdle: idle, started: started,
                       externalBusy: busy)
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
