import Foundation

/// v1.10 (L1): every engine operation DictateKit performs on the headset during one dictation,
/// counted (`io_ops=start:N stop:N rebuild:N retap:N` on the session end line), and the
/// hands-off rule on a Bluetooth input.
///
/// 10-13 07:00–07:10 (Archie 38.0, XM6): our IO context started/stopped on the headset ~6 times
/// in the first 1.3 s of every A2DP-start dictation; each stop while the SCO link was forming
/// dropped eSCO creation, and the headset mic never delivered. With HFP already up (R4) one start
/// and no stop brought the link up. The rule: from the first configuration-change notification,
/// exactly ONE re-attach (retap + start if AVAudioEngine auto-stopped; nothing if it still runs),
/// then NO engine stop/start/rebuild/format-align for `handsOff` (1.0 s). Inside the window a
/// mismatched hardware format is converted in the tap, never rebuilt. Other inputs are counted
/// but never held.
public struct HeadsetIOGuard: Sendable {
    public enum Op: String, Sendable { case start, stop, rebuild, retap, align }
    /// = `BluetoothRecoveryEpisode.successWithin`: the re-attach's verification window.
    public static let handsOff: TimeInterval = BluetoothRecoveryEpisode.successWithin

    public enum Reaction: Equatable, Sendable {
        /// The first notification and the engine auto-stopped: the one re-attach, now.
        case reattach
        /// The first notification and the engine still runs: leave it alone.
        case leaveRunning
        /// Inside the hands-off window: do nothing.
        case handsOff(until: TimeInterval)
        /// Not Bluetooth, or after the window: the episode's policy decides (v1.9).
        case episode
    }

    public let bluetooth: Bool
    public private(set) var starts = 0
    public private(set) var stops = 0
    public private(set) var rebuilds = 0
    public private(set) var retaps = 0
    public private(set) var aligns = 0
    /// AVAudioEngine configuration notifications that reached this dictation's Bluetooth handler
    /// (each one is an auto-stop or reconfiguration the OS did, not an operation of ours).
    public private(set) var notifications = 0
    /// Operations a caller wanted inside the window and deferred (or skipped) instead.
    public private(set) var held = 0
    /// End of the hands-off window (nil: no notification yet).
    public private(set) var handsOffUntil: TimeInterval?

    public init(bluetooth: Bool) { self.bluetooth = bluetooth }

    /// An `AVAudioEngineConfigurationChange` reached the engine at `now`.
    public mutating func configurationChanged(at now: TimeInterval, engineRunning: Bool) -> Reaction {
        notifications += 1
        guard bluetooth else { return .episode }
        guard let until = handsOffUntil else {
            handsOffUntil = now + Self.handsOff
            return engineRunning ? .leaveRunning : .reattach
        }
        if now < until { held += 1; return .handsOff(until: until) }
        return .episode
    }

    /// Whether an engine stop/start/rebuild/align may run at `now`.
    public func allows(at now: TimeInterval) -> Bool {
        guard bluetooth, let until = handsOffUntil else { return true }
        return now >= until
    }

    /// Seconds until the window closes (0 when operations are allowed).
    public func remaining(at now: TimeInterval) -> TimeInterval {
        guard bluetooth, let until = handsOffUntil else { return 0 }
        return max(0, until - now)
    }

    /// On Bluetooth, once the first notification arrived, a format mismatch is converted in the
    /// tap: `TapFormatPlan`'s rebuild and `alignClientFormat` may run only before it.
    public var convertsInTap: Bool { bluetooth && handsOffUntil != nil }

    /// A caller deferred an operation because of the window.
    public mutating func deferred() { held += 1 }

    public mutating func record(_ op: Op) {
        switch op {
        case .start: starts += 1
        case .stop: stops += 1
        case .rebuild: rebuilds += 1
        case .retap: retaps += 1
        case .align: aligns += 1
        }
    }

    /// `io_ops=start:N stop:N rebuild:N retap:N` (+ ` align:N` only when one ran).
    public var note: String {
        "io_ops=start:\(starts) stop:\(stops) rebuild:\(rebuilds) retap:\(retaps)" + (aligns > 0 ? " align:\(aligns)" : "")
    }
    /// `io_held=N config_notifications=N`.
    public var heldNote: String { "io_held=\(held) config_notifications=\(notifications)" }
}
