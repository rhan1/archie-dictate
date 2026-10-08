import Foundation

public enum DictationOutcome: Equatable, Sendable {
    case ok, cancel, error(String)
    public var label: String {
        switch self {
        case .ok: return "ok"
        case .cancel: return "cancel"
        case .error(let reason):
            return "error:" + String(reason.map { $0.isWhitespace ? "_" : $0 }.prefix(60))
        }
    }
}

public struct DictationLogEntry: Equatable, Sendable {
    public var time: Date
    public var durationSeconds: Double
    public var audioBytes: Int
    public var latencyMs: Int
    public var chars: Int
    public var frontmostBundleID: String
    public var outcome: DictationOutcome

    public init(time: Date, durationSeconds: Double, audioBytes: Int, latencyMs: Int,
                chars: Int, frontmostBundleID: String, outcome: DictationOutcome) {
        self.time = time
        self.durationSeconds = durationSeconds
        self.audioBytes = audioBytes
        self.latencyMs = latencyMs
        self.chars = chars
        self.frontmostBundleID = frontmostBundleID
        self.outcome = outcome
    }

    public func formatted(timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        formatter.timeZone = timeZone
        let duration = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), durationSeconds)
        let app = frontmostBundleID.isEmpty ? "unknown" : frontmostBundleID
        return "\(formatter.string(from: time)) duration=\(duration)s bytes=\(audioBytes) latency_ms=\(latencyMs) chars=\(chars) app=\(app) outcome=\(outcome.label)"
    }
}

public enum DictationLog {
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/logs/dictate.log")

    @discardableResult
    public static func append(_ entry: DictationLogEntry, to url: URL = defaultURL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return false }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((entry.formatted() + "\n").utf8))
            return true
        } catch { return false }
    }
}
