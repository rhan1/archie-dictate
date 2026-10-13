import Foundation
import Testing
@testable import DictateCore

/// v1.14: the rig's launch gate, trigger file and sink (pure; the AppKit wiring is RigInertTests).
@Suite("RigHooksTests")
struct RigHooksTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-rig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTrigger(_ text: String, at url: URL, mode: Int = 0o600) {
        FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    }

    /// Inert by default: only DICTATE_RIG exactly "1" with an absolute DICTATE_RIG_DIR turns the rig on.
    @Test func launchGateIsOffUnlessBothVariablesAreSet() {
        let off: [[String: String]] = [
            [:],
            ["DICTATE_RIG_DIR": "/tmp/rig"],
            ["DICTATE_RIG": "1"],
            ["DICTATE_RIG": "0", "DICTATE_RIG_DIR": "/tmp/rig"],
            ["DICTATE_RIG": "true", "DICTATE_RIG_DIR": "/tmp/rig"],
            ["DICTATE_RIG": "1", "DICTATE_RIG_DIR": "relative/rig"],
            ["DICTATE_RIG": "1", "DICTATE_RIG_DIR": "/tmp/../etc"],
        ]
        for env in off { #expect(RigConfig.fromLaunchEnvironment(env) == nil, "\(env)") }
        // Positive control: the one shape that enables it.
        let on = RigConfig.fromLaunchEnvironment(["DICTATE_RIG": "1", "DICTATE_RIG_DIR": "/tmp/rig"])
        #expect(on?.triggerURL.path == "/tmp/rig/trigger")
        #expect(on?.outURL.path == "/tmp/rig/out")
    }

    @Test func rowNamesAreFileSafe() {
        for good in ["1", "A1", "W2", "row_7-b", String(repeating: "x", count: 16)] { #expect(RigConfig.isValidRow(good), "\(good)") }
        for bad in ["", "../x", "a/b", "a b", "é", String(repeating: "x", count: 17), ".", "a.txt"] { #expect(!RigConfig.isValidRow(bad), "\(bad)") }
    }

    /// GREEN: a 0600 `chord <row>` file is read once and removed. RED: every other shape is removed unread.
    @Test func triggerFileAcceptsOnlyAPrivateChordLine() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("trigger")
        #expect(RigTriggerFile.consume(at: url) == .none)

        writeTrigger("chord A1\n", at: url)
        #expect(RigTriggerFile.consume(at: url) == .chord(row: "A1"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(RigTriggerFile.consume(at: url) == .none)

        writeTrigger("chord A1\n", at: url, mode: 0o644)
        #expect(RigTriggerFile.consume(at: url) == .rejected("mode"))
        #expect(!FileManager.default.fileExists(atPath: url.path))

        for text in ["chord", "chord ../x", "start A1", "chord A1 A2", ""] {
            writeTrigger(text, at: url)
            #expect(RigTriggerFile.consume(at: url) == .rejected("parse"), "\(text)")
        }
        writeTrigger(String(repeating: "x", count: RigTriggerFile.maxBytes + 1), at: url)
        #expect(RigTriggerFile.consume(at: url) == .rejected("size"))

        writeTrigger("chord A1", at: url)
        #expect(RigTriggerFile.consume(at: url, uid: getuid() + 1) == .rejected("owner"))

        let target = dir.appendingPathComponent("real")
        writeTrigger("chord A1", at: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(RigTriggerFile.consume(at: url) == .rejected("type"))
        #expect(FileManager.default.fileExists(atPath: target.path))      // the link went, never its target
    }

    @Test func sinkWritesTheRowFilePrivately() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = RigConfig(directory: dir)
        let url = try RigSink.write("first", row: "W1", config: config)
        try RigSink.write("second", row: "W1", config: config)
        #expect(url.path == dir.appendingPathComponent("out/W1.txt").path)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(throws: (any Error).self) { try RigSink.write("x", row: "../W1", config: config) }
    }
}
