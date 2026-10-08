import Foundation
import Testing
import DictateCore

private final class CannedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    let status: Int
    let body: String
    let error: Error?
    init(status: Int = 200, body: String = "", error: Error? = nil) { self.status = status; self.body = body; self.error = error }
    var last: URLRequest? { lock.withLock { request } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { self.request = request }
        if let error { throw error }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func completion(_ content: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    return String(decoding: data, as: UTF8.self)
}

@Suite("Cleanup")
struct CleanupTests {
    @Test func requestShape() async throws {
        let transport = CannedTransport(body: completion("ok"))
        let cleaner = TranscriptCleaner(transport: transport, model: "gpt-5.4-nano", vocabulary: "Limpar, DB99", apiKey: { "test-key" })
        _ = try await cleaner.clean("um hello")
        let request = try #require(transport.last)
        #expect(request.url == TranscriptCleaner.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "gpt-5.4-nano")
        #expect(body["temperature"] as? Int == 0)
        #expect(body["reasoning_effort"] as? String == "none")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"]?.contains("Never add, summarise, answer") == true)
        #expect(messages[0]["content"]?.hasSuffix("Vocabulary: Limpar, DB99") == true)
        #expect(messages[1] == ["role": "user", "content": "um hello"])
        #expect(body["prediction"] == nil)   // gpt-5 models: no predicted outputs
    }

    @Test func gpt4ModelsSendPredictedOutputOfTheRawText() throws {
        let cleaner = TranscriptCleaner(transport: CannedTransport(), model: "gpt-4.1-nano", vocabulary: "", apiKey: { "k" })
        let body = try #require(try JSONSerialization.jsonObject(with: cleaner.makeRequest(text: "um send it tuesday", apiKey: "k").httpBody!) as? [String: Any])
        #expect(body["prediction"] as? [String: String] == ["type": "content", "content": "um send it tuesday"])
    }

    @Test func shortTranscriptsSkipCleanup() {
        #expect(TranscriptCleaner.shouldClean("yes") == false)
        #expect(TranscriptCleaner.shouldClean("send it on Wednesday please") == false)        // 5 words
        #expect(TranscriptCleaner.shouldClean("um send it on Wednesday please") == true)      // 6 words
        #expect(TranscriptCleaner.shouldClean("  ") == false)
    }

    @Test func nonReasoningModelHasNoReasoningEffort() throws {
        let cleaner = TranscriptCleaner(transport: CannedTransport(), model: "gpt-4.1-nano", vocabulary: "", apiKey: { "k" })
        let body = try #require(try JSONSerialization.jsonObject(with: cleaner.makeRequest(text: "x", apiKey: "k").httpBody!) as? [String: Any])
        #expect(body["reasoning_effort"] == nil)
        #expect(cleaner.systemPrompt() == TranscriptCleaner.instructions)
    }

    @Test func returnsTrimmedContent() async throws {
        let cleaner = TranscriptCleaner(transport: CannedTransport(body: completion("  Send it Wednesday.\n")), vocabulary: "", apiKey: { "k" })
        #expect(try await cleaner.clean("send it tuesday no wednesday") == "Send it Wednesday.")
    }

    @Test func errorsMapForFallback() async {
        let auth = TranscriptCleaner(transport: CannedTransport(status: 401), vocabulary: "", apiKey: { "k" })
        await #expect(throws: TranscriptionError.auth) { try await auth.clean("x") }
        let slow = TranscriptCleaner(transport: CannedTransport(error: URLError(.timedOut)), vocabulary: "", apiKey: { "k" })
        await #expect(throws: TranscriptionError.network("timedOut")) { try await slow.clean("x") }
        let empty = TranscriptCleaner(transport: CannedTransport(body: completion("   ")), vocabulary: "", apiKey: { "k" })
        await #expect(throws: TranscriptionError.decode) { try await empty.clean("x") }
    }

    @Test func requestDeadlineIsTwoAndAHalfSeconds() {
        let cleaner = TranscriptCleaner(transport: CannedTransport(), vocabulary: "", apiKey: { "k" })
        #expect(cleaner.makeRequest(text: "x", apiKey: "k").timeoutInterval == 2.5)
    }
}

@Suite("LogLineV11")
struct LogLineV11Tests {
    @Test func v11FieldsAppendInOrder() {
        var entry = DictationLogEntry(time: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 14.5, audioBytes: 696_000,
                                      latencyMs: 980, chars: 40, frontmostBundleID: "com.apple.TextEdit", outcome: .ok)
        entry.path = "realtime"
        entry.sttMs = 412
        entry.cleanupMs = 560
        entry.cleanupModel = "gpt-5.4-nano"
        entry.cleanup = "ok"
        #expect(entry.formatted(timeZone: TimeZone(secondsFromGMT: 8 * 3600)!) ==
                "2027-01-15T16:00:00+08:00 duration=14.5s bytes=696000 latency_ms=980 chars=40 app=com.apple.TextEdit outcome=ok path=realtime stt_ms=412 cleanup_ms=560 model=gpt-5.4-nano cleanup=ok")
    }
}
