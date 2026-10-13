import Foundation

/// v1.14: the unattended headset rig's host hooks (`tools/rig/live-rig.zsh`). Test-only and inert
/// unless the host's LAUNCH environment carried `DICTATE_RIG=1` and an absolute `DICTATE_RIG_DIR`:
/// then a 0600 trigger file in that directory stands in for ⌥⌥ and the paste goes to
/// `<dir>/out/<row>.txt` instead of the frontmost app. No keystroke is ever synthesised.
public struct RigConfig: Equatable, Sendable {
    public let directory: URL
    public var triggerURL: URL { directory.appendingPathComponent("trigger") }
    public var outURL: URL { directory.appendingPathComponent("out", isDirectory: true) }

    public init(directory: URL) { self.directory = directory }

    /// nil (rig off) unless `DICTATE_RIG` is exactly "1" and `DICTATE_RIG_DIR` is an absolute path.
    public static func fromLaunchEnvironment(_ environment: [String: String]) -> RigConfig? {
        guard environment["DICTATE_RIG"] == "1", let dir = environment["DICTATE_RIG_DIR"],
              dir.hasPrefix("/"), !dir.contains("/../") else { return nil }
        return RigConfig(directory: URL(fileURLWithPath: dir, isDirectory: true))
    }

    /// A row names an output file: letters, digits, `_` and `-`, 1–16 characters.
    public static func isValidRow(_ row: String) -> Bool {
        (1...16).contains(row.count) && row.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}

/// One read of the trigger file. The only command is `chord <row>` (the operator's ⌥⌥).
public enum RigTriggerReading: Equatable, Sendable {
    case none
    case chord(row: String)
    /// The file was removed unread or unparsed: `type`, `owner`, `mode`, `size`, `read`, `parse`.
    case rejected(String)
}

public enum RigTriggerFile {
    public static let maxBytes = 256

    /// Reads and removes the trigger file. Only a regular file (never a symlink), owned by `uid`,
    /// mode exactly 0600, at most `maxBytes`, holding one `chord <row>` line is accepted; anything
    /// else is removed and reported as rejected.
    public static func consume(at url: URL, uid: uid_t = getuid()) -> RigTriggerReading {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .none }
        defer { unlink(url.path) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .rejected("type") }
        guard info.st_uid == uid else { return .rejected("owner") }
        guard info.st_mode & 0o777 == 0o600 else { return .rejected("mode") }
        guard info.st_size <= maxBytes else { return .rejected("size") }
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return .rejected("read") }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        guard words.count == 2, words[0] == "chord", RigConfig.isValidRow(String(words[1])) else { return .rejected("parse") }
        return .chord(row: String(words[1]))
    }
}

public enum RigSink {
    /// Writes the dictation's text to `<out>/<row>.txt` (directory 0700, file 0600), replacing it.
    @discardableResult
    public static func write(_ text: String, row: String, config: RigConfig) throws -> URL {
        guard RigConfig.isValidRow(row) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: config.outURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = config.outURL.appendingPathComponent("\(row).txt")
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
