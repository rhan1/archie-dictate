import Foundation
import Testing
import DictateCore

private struct CleanupReply: HTTPTransport {
    var body: Data
    var status = 200
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("CleanupRejectTests")
struct CleanupRejectTests {
    private let raw = "Send the report to Alice and do not send it to Bob."

    private func cleaner(output: String, reason: String?, endpoint: URL = TranscriptCleaner.groqEndpoint) throws -> TranscriptCleaner {
        var choice: [String: Any] = ["message": ["content": output]]
        if let reason { choice["finish_reason"] = reason }
        let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return TranscriptCleaner(transport: CleanupReply(body: data), endpoint: endpoint,
                                 model: "test-model", vocabulary: "", apiKey: { "FAKE" })
    }

    private func expectRejection(_ cleaner: TranscriptCleaner, input: String, reason: String) async {
        do {
            _ = try await cleaner.clean(input)
            Issue.record("Expected rejected_\(reason), but cleanup was accepted")
        } catch {
            #expect((error as? TranscriptionError)?.logReason == "rejected_\(reason)")
        }
    }

    @Test(arguments: [TranscriptCleaner.groqEndpoint, TranscriptCleaner.endpoint, TranscriptCleaner.ollamaEndpoint])
    func stopAccepted(endpoint: URL) async throws {
        let c = try cleaner(output: raw, reason: "stop", endpoint: endpoint)
        #expect(try await c.clean(raw) == raw)
    }

    // The native Ollama client is gone (lane A). Port its length reproduction through the
    // surviving OpenAI-compatible local endpoint as well as both cloud endpoints.
    @Test(arguments: ["length", "content_filter"], [TranscriptCleaner.groqEndpoint, TranscriptCleaner.endpoint, TranscriptCleaner.ollamaEndpoint])
    func incompleteCompletionRejected(reason: String, endpoint: URL) async throws {
        let c = try cleaner(output: raw, reason: reason, endpoint: endpoint)
        await expectRejection(c, input: raw, reason: reason)
    }

    @Test func missingFinishReasonRejected() async throws {
        await expectRejection(try cleaner(output: raw, reason: nil), input: raw, reason: "missing")
    }

    @Test func truncatedMeaningRejectedEvenWithStop() async throws {
        await expectRejection(try cleaner(output: "Send the report to Alice", reason: "stop"), input: raw, reason: "ratio")
    }

    @Test func expandedOutputRejected() async throws {
        await expectRejection(try cleaner(output: raw + " " + raw, reason: "stop"), input: raw, reason: "ratio")
    }

    @Test func normalCleanedOutputAccepted() async throws {
        let output = "Send the report to Alice, and do not send it to Bob."
        #expect(try await cleaner(output: output, reason: "stop").clean(raw) == output)
    }

    @Test func ratioUsesCollapsedWhitespace() async throws {
        let input = "Send     the\n\nreport\tto Alice and do not send it to Bob."
        #expect(try await cleaner(output: raw, reason: "stop").clean(input) == raw)
        let spaced = "Send" + String(repeating: " ", count: 80) + "the report to Alice"
        await expectRejection(try cleaner(output: spaced, reason: "stop"), input: raw, reason: "ratio")
    }

    @Test func ratioBoundariesAccepted() async throws {
        let input = "abcdefghij"
        #expect(try await cleaner(output: "abcde", reason: "stop").clean(input) == "abcde")
        #expect(try await cleaner(output: "abcdefghijklmno", reason: "stop").clean(input) == "abcdefghijklmno")
    }

    @Test(arguments: [401, 429, 500, 503])
    func httpErrorsPreserved(status: Int) async {
        let c = TranscriptCleaner(transport: CleanupReply(body: Data(), status: status), vocabulary: "", apiKey: { "FAKE" })
        let expected: TranscriptionError = status == 401 ? .auth : (status >= 500 ? .server(status) : .client(status))
        await #expect(throws: expected) { try await c.clean(raw) }
    }

    @Test func decodeAndMissingKeyPreserved() async {
        let decode = TranscriptCleaner(transport: CleanupReply(body: Data([0xff, 0xfe])), vocabulary: "", apiKey: { "FAKE" })
        await #expect(throws: TranscriptionError.decode) { try await decode.clean(raw) }
        let key = TranscriptCleaner(transport: CleanupReply(body: Data()), vocabulary: "", apiKey: { throw TranscriptionError.missingKey })
        await #expect(throws: TranscriptionError.missingKey) { try await key.clean(raw) }
    }
}
