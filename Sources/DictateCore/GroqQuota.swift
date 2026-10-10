import Foundation

/// Groq request/token headroom per endpoint. Counts and dates only, never keys or text.
public struct GroqQuota: Codable, Sendable, Equatable {
    public struct Snapshot: Codable, Sendable, Equatable {
        public var limitRequests: Int?
        public var remainingRequests: Int?
        public var limitTokens: Int?
        public var remainingTokens: Int?
        public var resetRequestsAt: Date?
        public var resetTokensAt: Date?
        public var updatedAt: Date?
        public init() {}
    }
    public var stt = Snapshot()
    public var cleanup = Snapshot()
    public init() {}

    /// The shared default store's counts (`~/Library/Application Support/Dictate/groq-quota.json`).
    public static var current: GroqQuota { GroqQuotaStore.shared.current }

    public func snapshot(_ endpoint: GroqRateLimit.Endpoint) -> Snapshot {
        endpoint == .stt ? stt : cleanup
    }

    /// A response that lacks a field keeps the prior value for that field only.
    public func merging(_ limits: GroqRateLimit, at date: Date) -> GroqQuota {
        var s = snapshot(limits.endpoint)
        let contributed = [limits.limitRequests, limits.remainingRequests, limits.limitTokens, limits.remainingTokens].contains { $0 != nil }
            || limits.resetRequests != nil || limits.resetTokens != nil
        guard contributed else { return self }   // a header-less response must not refresh staleness
        s.limitRequests = limits.limitRequests ?? s.limitRequests
        s.remainingRequests = limits.remainingRequests ?? s.remainingRequests
        s.limitTokens = limits.limitTokens ?? s.limitTokens
        s.remainingTokens = limits.remainingTokens ?? s.remainingTokens
        if let reset = limits.resetRequests { s.resetRequestsAt = date.addingTimeInterval(reset) }
        if let resetTokens = limits.resetTokens { s.resetTokensAt = date.addingTimeInterval(resetTokens) }
        s.updatedAt = date
        var copy = self
        if limits.endpoint == .stt { copy.stt = s } else { copy.cleanup = s }
        return copy
    }

    /// Remaining tokens are fresh within the reset window (or within 60s if no reset time).
    public func freshRemainingTokens(_ endpoint: GroqRateLimit.Endpoint, at now: Date = Date()) -> Int? {
        let s = snapshot(endpoint)
        guard let remaining = s.remainingTokens else { return nil }
        if let reset = s.resetTokensAt {
            guard now < reset else { return nil }
            return remaining
        }
        guard let updated = s.updatedAt else { return nil }
        guard now.timeIntervalSince(updated) < 60 else { return nil }
        return remaining
    }

    /// Under 10 % of the request window left and the counts are still current. Counts expire at
    /// the reset time (or 15 min after the last response when there is none): in fallback no
    /// Groq call refreshes them, so without expiry the fallback could never end.
    public func isLow(_ endpoint: GroqRateLimit.Endpoint, at now: Date) -> Bool {
        let s = snapshot(endpoint)
        guard let limit = s.limitRequests, limit > 0, let remaining = s.remainingRequests,
              remaining * 10 < limit else { return false }
        if let reset = s.resetRequestsAt { return now < reset }
        guard let updated = s.updatedAt else { return false }
        return now.timeIntervalSince(updated) < 15 * 60
    }
}

/// Thread-safe holder that persists every recorded response to a JSON file (atomic writes).
public final class GroqQuotaStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var quota: GroqQuota

    public static let shared = GroqQuotaStore(fileURL: defaultFileURL())

    public static func defaultFileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        defaultFileURL(for: AppPaths(home: home))
    }
    /// Beside the other Application Support files of an injected `AppPaths`.
    public static func defaultFileURL(for paths: AppPaths) -> URL {
        paths.mutedStateURL.deletingLastPathComponent().appendingPathComponent("groq-quota.json")
    }

    /// A missing or corrupt file starts empty.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        quota = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode(GroqQuota.self, from: $0) } ?? GroqQuota()
    }

    public var current: GroqQuota { lock.withLock { quota } }

    public func record(_ limits: GroqRateLimit, at date: Date = Date()) {
        lock.withLock {
            let merged = quota.merging(limits, at: date)
            guard merged != quota else { return }
            quota = merged
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(merged) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)   // best effort, like the other diagnostics
        }
    }
}
