import Foundation

/// Lifetime-only key cache. Readers may block on system UI; callers never wait for them.
public final class KeyStore: @unchecked Sendable {
    public enum Missing: String, Sendable { case pending, denied }
    private enum Entry { case pending, available(String), denied(at: TimeInterval) }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dictate.keys", qos: .utility, attributes: .concurrent)
    private let reader: @Sendable (String) throws -> String
    private let clock: @Sendable () -> TimeInterval
    private var entries: [String: Entry] = [:]
    private var reasons: [String: String] = [:]

    /// The default reader: `/usr/bin/security` (never a keychain dialog). SecItem is opt-in via `KeychainAPIKey.read`.
    public static let defaultReaderName = "security-tool"
    public init(reader: @escaping @Sendable (String) throws -> String = { try KeychainToolReader().read(service: $0) },
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reader = reader
        self.clock = clock
    }
    public func prefetch(services: [String]) {
        for service in services {
            let start = lock.withLock {
                guard entries[service] == nil else { return false }
                entries[service] = .pending
                return true
            }
            if start { readInBackground(service) }
        }
    }
    public func key(for service: String) -> String? {
        let (key, retry): (String?, Bool) = lock.withLock {
            switch entries[service] {
            case .available(let key): return (key, false)
            case .denied(let failedAt) where clock() - failedAt >= 60:
                entries[service] = .pending
                return (nil, true)
            default: return (nil, false)
            }
        }
        if retry { readInBackground(service) }
        return key
    }
    /// `prompt_suppressed` when the last failed read would have needed a keychain dialog.
    public func failureReason(for service: String) -> String? { lock.withLock { reasons[service] } }
    public func missing(for service: String) -> Missing? {
        lock.withLock {
            switch entries[service] {
            case .available: return nil
            case .denied: return .denied
            default: return .pending
            }
        }
    }
    private func readInBackground(_ service: String) {
        queue.async { [self] in
            var reason: String?
            let value: String?
            do { value = try reader(service).trimmingCharacters(in: .whitespacesAndNewlines) }
            catch { value = nil; reason = error as? KeyReadError == .promptSuppressed ? "prompt_suppressed" : nil }
            lock.withLock {
                if let value, !value.isEmpty { entries[service] = .available(value); reasons[service] = nil }
                else { entries[service] = .denied(at: clock()); reasons[service] = reason }
            }
        }
    }
}
