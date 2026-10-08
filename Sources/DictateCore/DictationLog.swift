import Foundation

public enum DictationOutcome: Equatable, Sendable {
    case ok, cancel, error(String), held(String)
    public var label: String {
        switch self {
        case .ok: return "ok"
        case .cancel: return "cancel"
        case .error(let reason):
            return "error:" + String(reason.map { $0.isWhitespace ? "_" : $0 }.prefix(60))
        case .held(let reason):
            return "held:" + String(reason.map { $0.isWhitespace ? "_" : $0 }.prefix(60))
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
    // v1.1 (A1/A3): which STT path ran, how long STT and cleanup took after
    // the finish tap, and the cleanup model / result. Omitted from the line
    // when nil so v1 lines keep their exact shape.
    public var path: String?
    public var sttMs: Int?
    public var cleanupMs: Int?
    public var cleanupModel: String?
    public var cleanup: String?
    public var cleanupMode: String?
    public var chunks: Int?
    public var lastChunkMs: Int?
    public var chunkFallback: Int?

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
        var line = "\(formatter.string(from: time)) duration=\(duration)s bytes=\(audioBytes) latency_ms=\(latencyMs) chars=\(chars) app=\(app) outcome=\(outcome.label)"
        if let path { line += " path=\(path)" }
        if let sttMs { line += " stt_ms=\(sttMs)" }
        if let chunks { line += " chunks=\(chunks)" }
        if let lastChunkMs { line += " last_chunk_ms=\(lastChunkMs)" }
        if let chunkFallback { line += " chunk_fallback=\(chunkFallback)" }
        if let cleanupMs { line += " cleanup_ms=\(cleanupMs)" }
        if let cleanupModel { line += " model=\(cleanupModel)" }
        if let cleanup { line += " cleanup=\(cleanup)" }
        if let cleanupMode { line += " cleanup_mode=\(cleanupMode)" }
        return line
    }
}

public enum DictationLog {
    public static let defaultURL = AppPaths().logURL

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
