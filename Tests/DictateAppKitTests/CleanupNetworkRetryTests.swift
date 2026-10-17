import Foundation
import Testing
@testable import DictateAppKit
import DictateCore

/// M2 (2026-10-17 00:43): cleanup failed once on the network (`network_-1004`, cannot connect) and
/// the raw Whisper loop was pasted. One bounded Groq retry now runs before the local/raw fallback.
@Suite("Cleanup network retry (M2)")
struct CleanupNetworkRetryTests {
    actor Transport: HTTPTransport {
        enum Step { case fail(URLError.Code), ok(String) }
        private var steps: [Step]
        private(set) var requests: [URLRequest] = []
        init(_ steps: [Step]) { self.steps = steps }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !steps.isEmpty else { throw URLError(.cannotConnectToHost) }
            switch steps.removeFirst() {
            case .fail(let code): throw URLError(code)
            case .ok(let content):
                let body = try JSONSerialization.data(withJSONObject: [
                    "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": content]]]])
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    static func cleaners(groq: Transport, local: Transport) -> (TranscriptCleaner, TranscriptCleaner) {
        (TranscriptCleaner(transport: groq, endpoint: TranscriptCleaner.groqEndpoint, model: "qwen/qwen3.8-27b",
                           vocabulary: "", apiKey: { "k" }),
         TranscriptCleaner(transport: local, endpoint: TranscriptCleaner.ollamaEndpoint, model: "llama3.2:3b",
                           vocabulary: "", apiKey: { "k" }))
    }

    @Test func oneNetworkFailureIsRetriedOnGroq() async throws {
        let groqT = Transport([.fail(.cannotConnectToHost), .ok("Testing.")])
        let localT = Transport([.ok("Local winner.")])
        let (groq, local) = Self.cleaners(groq: groqT, local: localT)
        let result = await AppController.cleanUp("testing", groq: groq, local: local)
        #expect(result.text == "Testing.")
        #expect(result.label == "ok")
        #expect(result.calls == 2)
        let requests = await groqT.requests
        #expect(requests.count == 2)
        #expect(requests.count == 2 && requests[1].timeoutInterval <= 1.5)   // the retry is bounded
        #expect(await localT.requests.isEmpty)
    }

    @Test func twoNetworkFailuresFallBackWithExactlyTwoGroqCalls() async throws {
        let groqT = Transport([.fail(.cannotConnectToHost), .fail(.cannotConnectToHost)])
        let localT = Transport([.fail(.cannotConnectToHost)])
        let (groq, local) = Self.cleaners(groq: groqT, local: localT)
        let raw = "Testing."   // already guarded by RepetitionGuard upstream
        let result = await AppController.cleanUp(raw, groq: groq, local: local)
        #expect(result.text == raw)
        #expect(result.label.hasPrefix("skipped:network"))
        let requests = await groqT.requests
        #expect(requests.count == 2 && requests[1].timeoutInterval <= 1.5)
    }
}
