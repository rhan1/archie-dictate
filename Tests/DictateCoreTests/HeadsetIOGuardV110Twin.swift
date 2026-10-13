import Foundation
@testable import DictateCore

/// The RED twin for v1.12 L2: v1.10's `HeadsetIOGuard`, verbatim (main @ 1b7f913) except the type
/// name and access level. It decides from a blind 1.0 s window; v1.12 decides from observed IO.
struct HeadsetIOGuardV110: Sendable {
    enum Op: String, Sendable { case start, stop, rebuild, retap, align }
    /// = `BluetoothRecoveryEpisode.successWithin`: the re-attach's verification window.
    static let handsOff: TimeInterval = BluetoothRecoveryEpisode.successWithin

    enum Reaction: Equatable, Sendable {
        /// The first notification and the engine auto-stopped: the one re-attach, now.
        case reattach
        /// The first notification and the engine still runs: leave it alone.
        case leaveRunning
        /// Inside the hands-off window: do nothing.
        case handsOff(until: TimeInterval)
        /// Not Bluetooth, or after the window: the episode's policy decides (v1.9).
        case episode
    }

    let bluetooth: Bool
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var rebuilds = 0
    private(set) var retaps = 0
    private(set) var aligns = 0
    /// AVAudioEngine configuration notifications that reached this dictation's Bluetooth handler
    /// (each one is an auto-stop or reconfiguration the OS did, not an operation of ours).
    private(set) var notifications = 0
    /// Operations a caller wanted inside the window and deferred (or skipped) instead.
    private(set) var held = 0
    /// End of the hands-off window (nil: no notification yet).
    private(set) var handsOffUntil: TimeInterval?

    init(bluetooth: Bool) { self.bluetooth = bluetooth }

    /// An `AVAudioEngineConfigurationChange` reached the engine at `now`.
    mutating func configurationChanged(at now: TimeInterval, engineRunning: Bool) -> Reaction {
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
    func allows(at now: TimeInterval) -> Bool {
        guard bluetooth, let until = handsOffUntil else { return true }
        return now >= until
    }

    /// Seconds until the window closes (0 when operations are allowed).
    func remaining(at now: TimeInterval) -> TimeInterval {
        guard bluetooth, let until = handsOffUntil else { return 0 }
        return max(0, until - now)
    }

    /// On Bluetooth, once the first notification arrived, a format mismatch is converted in the
    /// tap: `TapFormatPlan`'s rebuild and `alignClientFormat` may run only before it.
    var convertsInTap: Bool { bluetooth && handsOffUntil != nil }

    /// A caller deferred an operation because of the window.
    mutating func deferred() { held += 1 }

    mutating func record(_ op: Op) {
        switch op {
        case .start: starts += 1
        case .stop: stops += 1
        case .rebuild: rebuilds += 1
        case .retap: retaps += 1
        case .align: aligns += 1
        }
    }

    /// `io_ops=start:N stop:N rebuild:N retap:N` (+ ` align:N` only when one ran).
    var note: String {
        "io_ops=start:\(starts) stop:\(stops) rebuild:\(rebuilds) retap:\(retaps)" + (aligns > 0 ? " align:\(aligns)" : "")
    }
    /// `io_held=N config_notifications=N`.
    var heldNote: String { "io_held=\(held) config_notifications=\(notifications)" }
}
