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
    var isDelivering: Bool { get }
    /// Read back from the unit now (nil: unreadable or not started).
    var currentDeviceID: UInt32? { get }
    /// The built-in device resolved at start.
    var expectedDeviceID: UInt32? { get }
    var lastBufferTime: TimeInterval? { get }
    /// Timeline value: `auhal` (or `avcapture` if that backend ever ships).
    var backend: String { get }
}

public extension BuiltinCapture {
    /// The health clock's device read-back: ok, drift (another device), or unreadable.
    func deviceCheck() -> BuiltinPin.Check? {
        guard let expected = expectedDeviceID else { return nil }
        guard let current = currentDeviceID else { return .drift(from: 0) }
        return current == expected ? .ok : .drift(from: current)
    }
}
