import Foundation

/// The output device's MUTE FLAG only — no volume level is ever read or written
/// while recording. The volume level is never changed.
public protocol OutputMuteDevice: AnyObject {
    func defaultOutputUID() -> String?
    /// nil when the device is gone or has no settable mute flag.
    func isMuted(uid: String) -> Bool?
    func setMuted(_ muted: Bool, uid: String) -> Bool
}

/// Mutes the default output while recording and restores the exact prior
/// flag on the SAME device (by UID) afterwards. A state file survives crashes.
public final class OutputMuter {
    public enum Event: String, Sendable {
        case muted, restored, unmuteRecovered = "unmute_recovered", unsupported, none, restorePending = "restore_pending"
    }

    private let device: OutputMuteDevice
    private let stateFile: URL
    public private(set) var mutedUID: String?
    private var prior = false

    public static let defaultStateFile = AppPaths().mutedStateURL

    public init(device: OutputMuteDevice, stateFile: URL = OutputMuter.defaultStateFile) {
        self.device = device
        self.stateFile = stateFile
    }

    /// Recording went live. `.unsupported` tells the caller to fall back to pausing.
    public func mute() -> Event {
        guard mutedUID == nil else { return .muted }
        guard let uid = device.defaultOutputUID() else { return .none }
        guard let current = device.isMuted(uid: uid) else { return .unsupported }
        prior = current
        // Record BEFORE muting, so a crash in between can still be undone.
        writeState(uid: uid, prior: current)
        guard device.setMuted(true, uid: uid) else {
            try? FileManager.default.removeItem(at: stateFile)
            return .unsupported
        }
        mutedUID = uid
        return .muted
    }

    /// Every end path. Restores the prior flag on the device we muted, even if
    /// another device is the default now. Idempotent.
    @discardableResult
    public func restore() -> Event? {
        guard let uid = mutedUID else { return nil }
        guard device.setMuted(prior, uid: uid) else { return .restorePending }   // device gone: file kept for recovery
        mutedUID = nil
        try? FileManager.default.removeItem(at: stateFile)
        return .restored
    }

    /// App launch (and before each mute): undo a mute a crashed run left behind.
    @discardableResult
    public func recoverIfNeeded() -> Event? {
        guard mutedUID == nil,
              let text = try? String(contentsOf: stateFile, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\t").map(String.init)
        guard parts.count == 2 else {
            try? FileManager.default.removeItem(at: stateFile)
            return nil
        }
        guard device.setMuted(parts[1] == "1", uid: parts[0]) else { return .restorePending }
        try? FileManager.default.removeItem(at: stateFile)
        return .unmuteRecovered
    }

    private func writeState(uid: String, prior: Bool) {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(uid)\t\(prior ? 1 : 0)".write(to: stateFile, atomically: true, encoding: .utf8)
    }
}
