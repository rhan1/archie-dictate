import Foundation

/// Standard macOS locations. Inject a home directory to isolate tests.
public struct AppPaths: Sendable {
    public let logURL: URL
    public let stderrURL: URL
    public let mutedStateURL: URL
    public let vocabularyURL: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let logs = home.appendingPathComponent("Library/Logs/Dictate", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/Dictate", isDirectory: true)
        logURL = logs.appendingPathComponent("dictate.log")
        stderrURL = logs.appendingPathComponent("dictate.stderr.log")
        mutedStateURL = support.appendingPathComponent("muted.state")
        vocabularyURL = support.appendingPathComponent("vocab-hints.txt")
    }

    /// Copies legacy state only when its destination is missing. Originals remain intact.
    /// No transcript or vocabulary file is migrated.
    @discardableResult
    public static func migrate(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [String] {
        let paths = AppPaths(home: home)
        let files = [
            (".claude/logs/dictate.log", paths.logURL),
            (".claude/logs/dictate.stderr.log", paths.stderrURL),
            (".claude/run-status/dictate-muted", paths.mutedStateURL),
        ]
        let manager = FileManager.default
        var copied: [String] = []
        for (legacy, destination) in files {
            let source = home.appendingPathComponent(legacy)
            guard !manager.fileExists(atPath: destination.path),
                  manager.fileExists(atPath: source.path) else { continue }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: destination)
            copied.append(destination.lastPathComponent)
        }
        return copied
    }
}
