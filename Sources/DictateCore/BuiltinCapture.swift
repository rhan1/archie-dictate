import Foundation

/// v1.8 (L1): the built-in microphone capture the bridge owns. The production unit is a raw
/// AUHAL bound to the physical built-in device (no AVAudioEngine, no default-device tracking,
/// no aggregate); tests inject a fake. Frames are 24 kHz mono Float with host-clock start times.
public protocol BuiltinCapture: AnyObject {
    /// Converted frames, on the unit's worker queue (never the real-time IO thread).
    var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)? { get set }
    /// The device disappeared or stopped being alive.
    var onDeviceLost: ((CaptureEpoch) -> Void)? { get set }
    /// Resolves the built-in device and starts IO. Synchronous; throws with the failing step.
    func start(epoch: CaptureEpoch) throws
    /// Idempotent; also after a partial start.
    func stop()
    /// Stops only if the unit is still running for `epoch` (stale cleanup never stops a reused unit).
    func stop(epoch: CaptureEpoch)
    var isDelivering: Bool { get }
    /// Read back from the unit now (nil: unreadable or not started).
    var currentDeviceID: UInt32? { get }
    /// The built-in device resolved at start.
    var expectedDeviceID: UInt32? { get }
    var lastBufferTime: TimeInterval? { get }
    /// Timeline value: `auhal` (or `avcapture` if that backend ever ships).
    var backend: String { get }
    /// v1.27 (B1): `start(epoch:)` has returned successfully and the unit has not been stopped since.
    /// Set by the unit itself, on its own queue, after the start returns.
    var started: Bool { get }
}

public extension BuiltinCapture {
    /// The health clock's device read-back: ok, drift (another device), or unreadable.
    /// v1.27 (B1): nil until the unit's own start has returned — a unit still starting is never checked
    /// (cc891096: the read-back of an uninitialised AUHAL was reported as `drift from=0`).
    func deviceCheck() -> BuiltinPin.Check? {
        guard started, let expected = expectedDeviceID else { return nil }
        guard let current = currentDeviceID else { return .unreadable }
        return current == expected ? .ok : .drift(from: current)
    }
}

/// v1.27 (B1): what the recorder does with one built-in device read-back, or a device-lost event.
public enum BuiltinWatch {
    public enum Verdict: Equatable, Sendable {
        /// Nothing to do (ok, corrected, or the unit has not started).
        case none
        /// Unreadable: log `bridge_device_check=unreadable` and read again on the next tick.
        case recheck
        /// A genuine loss while the headset is still starting: one new unit, same epoch
        /// (`builtin_rebuilt=1 reason=<drift|lost>`).
        case rebuild(CaptureHealth.Problem)
        /// v1.8: the built-in is dead for this dictation (`bridge_builtin_lost=1`).
        case dead(CaptureHealth.Problem)
    }

    public static func judge(_ check: BuiltinPin.Check?, headsetStarting: Bool, rebuilt: Bool) -> Verdict {
        switch check {
        case nil, .ok?, .corrected?: return .none
        case .unreadable?: return .recheck
        case .drift?: return judge(problem: .drift, headsetStarting: headsetStarting, rebuilt: rebuilt)
        }
    }

    /// A drift or a device-lost event: rebuilt once while the headset cannot carry yet, else dead.
    public static func judge(problem: CaptureHealth.Problem, headsetStarting: Bool, rebuilt: Bool) -> Verdict {
        headsetStarting && !rebuilt ? .rebuild(problem) : .dead(problem)
    }
}
