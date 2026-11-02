import Foundation
import Testing
@testable import DictateCore

/// v1.27 B3: the trace writer's format, permissions and one-line-per-event rule.
@Suite("V127TranscriptTrace")
struct V127TranscriptTraceTests {
    @Test func writesOneLinePerEventWith0600() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v127-tt-\(UUID().uuidString)/trace")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let trace = try #require(TranscriptTrace(directory: dir, sessionID: "abcd1234"))
        trace.chunk(index: 0, final: false, prompt: "full", raw: "Please send the report.")
        trace.chunk(index: 1, final: true, prompt: "skipped", raw: "")
        trace.cleaned("Please send\nthe report.")
        trace.pasted("Please send the report.")
        let text = try String(contentsOf: dir.appendingPathComponent("abcd1234.txt"), encoding: .utf8)
        #expect(text == "chunk=0 final=0 prompt=full raw=Please send the report.\nchunk=1 final=1 prompt=skipped raw=\ncleaned=Please send\\nthe report.\npasted=Please send the report.\n")
        #expect(trace.lines == 4)
        let file = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("abcd1234.txt").path)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect(file[.posixPermissions] as? Int == 0o600 && folder[.posixPermissions] as? Int == 0o700)
    }

    @Test func offUnlessTheKeyIsTrue() {
        let name = "dictate-v127-tt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!TranscriptTrace.enabled(defaults))
        defaults.set(false, forKey: TranscriptTrace.key)
        #expect(!TranscriptTrace.enabled(defaults))
        defaults.set(true, forKey: TranscriptTrace.key)
        #expect(TranscriptTrace.enabled(defaults))
    }
}
