import Foundation
import Testing
import DictateCore

@Suite("DictationLog")
struct LogLineTests {
    private func entry(outcome: DictationOutcome = .ok, app: String = "com.apple.TextEdit") -> DictationLogEntry {
        DictationLogEntry(time: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 5.2,
                          audioBytes: 166444, latencyMs: 812, chars: 42,
                          frontmostBundleID: app, outcome: outcome)
    }

    @Test func exactFormattedLine() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        #expect(entry().formatted(timeZone: zone) ==
                "2027-01-15T16:00:00+08:00 duration=5.2s bytes=166444 latency_ms=812 chars=42 app=com.apple.TextEdit outcome=ok")
    }
    @Test func cancelLabel() {
        #expect(DictationOutcome.cancel.label == "cancel")
        #expect(entry(outcome: .cancel).formatted().hasSuffix("outcome=cancel"))
    }
    @Test func errorSanitizesAndTruncates() {
        #expect(DictationOutcome.error("bad response\ttry\nagain").label == "error:bad_response_try_again")
        let reason = "a b " + String(repeating: "z", count: 100)
        #expect(DictationOutcome.error(reason).label == "error:a_b_" + String(repeating: "z", count: 56))
        #expect(DictationOutcome.error(reason).label.count == 66)
    }
    @Test func emptyBundleUsesUnknown() {
        #expect(entry(app: "").formatted().contains("app=unknown outcome=ok"))
    }
    @Test func appendCreatesParentsAndWritesTwoLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/dictate.log")
        let first = entry()
        let second = entry(outcome: .cancel)
        #expect(DictationLog.append(first, to: url))
        #expect(DictationLog.append(second, to: url))
        let actual = try String(contentsOf: url, encoding: .utf8)
        #expect(actual == first.formatted() + "\n" + second.formatted() + "\n")
        #expect(actual.split(separator: "\n").count == 2)
    }
    @Test func neverContainsTranscript() {
        let line = entry().formatted()
        #expect(!line.contains("transcript"))
        #expect(!line.contains("text="))
        #expect(!line.contains("\n"))
    }
    @Test func appendFailureReturnsFalse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: blocker)
        #expect(!DictationLog.append(entry(), to: blocker.appendingPathComponent("dictate.log")))
        #expect(try Data(contentsOf: blocker) == Data("not a directory".utf8))
    }
}
