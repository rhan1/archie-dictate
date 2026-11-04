import Foundation

/// v1.27 (B3): an opt-in, LOCAL-ONLY record of what each chunk returned, what the cleaner made of it and
/// what was pasted — the evidence path for "random words at the end" that `dictate.log` (counts only,
/// never text) cannot give. Off by default:
/// `defaults write com.razakhan.dictate DictateTranscriptTrace -bool true` turns it on; it is read at each
/// session start. When off, no `TranscriptTrace` exists, so nothing is created, formatted or written.
/// When on: `~/Library/Logs/Dictate/trace/<session-id>.txt` (directory 0700, file 0600), one line per event:
/// `chunk=<i> final=<0|1> prompt=<full|none> raw=<text>`, `chunk=<i> segments=[…]|none` (v1.28 FR5), `cleaned=<text>`, and `pasted=<text>` only when the
/// paste/type (or a capture-only host's delivery) succeeded. The file is closed when the session ends.
/// Nothing here is uploaded or sent anywhere.
public final class TranscriptTrace: @unchecked Sendable {
    public static let domain = "com.razakhan.dictate"
    public static let key = "DictateTranscriptTrace"

    /// The preference, from `defaults` (a host's own pass-through) or, when nil, the Dictate domain.
    public static func enabled(_ defaults: UserDefaults? = nil) -> Bool {
        if let defaults { return defaults.bool(forKey: key) }
        if Bundle.main.bundleIdentifier == domain { return UserDefaults.standard.bool(forKey: key) }
        return UserDefaults(suiteName: domain)?.bool(forKey: key) ?? false
    }

    /// `<logs>/trace` beside `dictate.log`.
    public static func directory(logURL: URL) -> URL {
        logURL.deletingLastPathComponent().appendingPathComponent("trace", isDirectory: true)
    }

    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    public private(set) var lines = 0

    /// nil when the file cannot be created (the dictation goes on untraced).
    public init?(directory: URL, sessionID: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            url = directory.appendingPathComponent("\(sessionID).txt")
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            handle = try FileHandle(forWritingTo: url)
        } catch { return nil }
    }

    deinit { try? handle?.close() }

    /// FR1-F: the session ended — the file is closed and later writes are ignored.
    public func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
    public var isClosed: Bool { lock.withLock { handle == nil } }

    public func chunk(index: Int, final: Bool, prompt: String, raw: String) {
        write("chunk=\(index) final=\(final ? 1 : 0) prompt=\(prompt) raw=\(raw)")
    }
    /// v1.28 FR5-A: Whisper's segments for chunk `index` with their confidences (`SegmentConfidence.describe`), or `none`.
    public func segments(index: Int, _ description: String) { write("chunk=\(index) segments=\(description)") }
    /// v1.28 FR3-C: what each cleaner call was given (input vs `cleaned=` output).
    public func cleanerIn(_ text: String) { write("cleaner_in=\(text)") }
    public func cleaned(_ text: String) { write("cleaned=\(text)") }
    public func pasted(_ text: String) { write("pasted=\(text)") }

    private func write(_ line: String) {
        let flat = line.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
        lock.withLock {
            guard let handle else { return }
            try? handle.write(contentsOf: Data((flat + "\n").utf8))
            lines += 1
        }
    }
}
