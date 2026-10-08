import Foundation
import Testing
import DictateCore

private func withTemporaryHome(_ body: (URL) throws -> Void) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-paths-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try body(home)
}

private func writeFixture(_ value: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try value.write(to: url, atomically: true, encoding: .utf8)
}

@Suite("AppPaths")
struct AppPathsTests {
    @Test func pathsUseInjectedHome() throws {
        try withTemporaryHome { home in
            let paths = AppPaths(home: home)
            #expect(paths.logURL == home.appendingPathComponent("Library/Logs/Dictate/dictate.log"))
            #expect(paths.stderrURL == home.appendingPathComponent("Library/Logs/Dictate/dictate.stderr.log"))
            #expect(paths.mutedStateURL == home.appendingPathComponent("Library/Application Support/Dictate/muted.state"))
            #expect(paths.vocabularyURL == home.appendingPathComponent("Library/Application Support/Dictate/vocab-hints.txt"))
            #expect(DictationLog.defaultURL == AppPaths().logURL)
            #expect(OutputMuter.defaultStateFile == AppPaths().mutedStateURL)
        }
    }

    @Test func migrationCopiesWithoutMovingAndSecondRunDoesNothing() throws {
        try withTemporaryHome { home in
            let paths = AppPaths(home: home)
            let pairs = [
                (home.appendingPathComponent(".claude/logs/dictate.log"), paths.logURL, "log fixture"),
                (home.appendingPathComponent(".claude/logs/dictate.stderr.log"), paths.stderrURL, "stderr fixture"),
                (home.appendingPathComponent(".claude/run-status/dictate-muted"), paths.mutedStateURL, "headset\t0"),
            ]
            for (source, _, value) in pairs { try writeFixture(value, to: source) }
            #expect(try AppPaths.migrate(home: home) == ["dictate.log", "dictate.stderr.log", "muted.state"])
            for (source, destination, value) in pairs {
                #expect(try String(contentsOf: source, encoding: .utf8) == value)
                #expect(try String(contentsOf: destination, encoding: .utf8) == value)
                try writeFixture("changed legacy", to: source)
            }
            #expect(try AppPaths.migrate(home: home).isEmpty)
            for (_, destination, value) in pairs {
                #expect(try String(contentsOf: destination, encoding: .utf8) == value)
            }
            #expect(!FileManager.default.fileExists(atPath: paths.vocabularyURL.path))
        }
    }

    @Test func noSourcesMeansNoCopiesOrDirectories() throws {
        try withTemporaryHome { home throws in
            #expect(try AppPaths.migrate(home: home).isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        }
    }

    @Test func existingDestinationsWinIndependently() throws {
        try withTemporaryHome { home in
            let paths = AppPaths(home: home)
            try writeFixture("old log", to: home.appendingPathComponent(".claude/logs/dictate.log"))
            try writeFixture("old stderr", to: home.appendingPathComponent(".claude/logs/dictate.stderr.log"))
            try writeFixture("current log", to: paths.logURL)
            #expect(try AppPaths.migrate(home: home) == ["dictate.stderr.log"])
            #expect(try String(contentsOf: paths.logURL, encoding: .utf8) == "current log")
            #expect(try String(contentsOf: paths.stderrURL, encoding: .utf8) == "old stderr")
        }
    }

    @Test func muteRecoveryUsesMigratedStateAndLeavesLegacyCopy() throws {
        try withTemporaryHome { home in
            let legacy = home.appendingPathComponent(".claude/run-status/dictate-muted")
            try writeFixture("headset\t0", to: legacy)
            #expect(try AppPaths.migrate(home: home) == ["muted.state"])
            let device = FakeOutput()
            device.mute["headset"] = true
            let muter = OutputMuter(device: device, stateFile: AppPaths(home: home).mutedStateURL)
            #expect(muter.recoverIfNeeded() == .unmuteRecovered)
            #expect(device.mute["headset"] == false)
            #expect(!FileManager.default.fileExists(atPath: AppPaths(home: home).mutedStateURL.path))
            #expect(try String(contentsOf: legacy, encoding: .utf8) == "headset\t0")
        }
    }
}
