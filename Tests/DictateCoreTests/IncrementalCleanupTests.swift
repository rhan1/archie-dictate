import Foundation
import Testing
import DictateCore

private actor IncrementalTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    private var maximum = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            maximum = max(maximum, pending.count)
        }
    }
    var count: Int { requests.count }
    var maxInFlight: Int { maximum }
    func body(_ index: Int) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: requests[index].httpBody!) as! [String: Any]
    }
    func user(_ index: Int) throws -> String {
        (try body(index)["messages"] as! [[String: String]]).last!["content"]!
    }
    func wait(_ count: Int) async throws {
        for _ in 0..<2000 {
            if requests.count >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw URLError(.timedOut)
    }
    func respond(_ index: Int, _ content: String, status: Int = 200, reason: String = "stop") throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": reason, "message": ["content": content]]],
        ])
        pending.removeValue(forKey: index)!.resume(returning: (data, HTTPURLResponse(
            url: TranscriptCleaner.groqEndpoint, statusCode: status, httpVersion: nil, headerFields: nil)!))
    }
    func fail(_ index: Int) {
        pending.removeValue(forKey: index)!.resume(throwing: URLError(.timedOut))
    }
    func malformed(_ index: Int) {
        pending.removeValue(forKey: index)!.resume(returning: (Data([0xff]), HTTPURLResponse(
            url: TranscriptCleaner.groqEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
}

@Suite("IncrementalCleanup")
struct IncrementalCleanupTests {
    private func cleaner(_ transport: IncrementalTransport) -> TranscriptCleaner {
        var cleaner = TranscriptCleaner(transport: transport, vocabulary: "", apiKey: { "hermetic-key" })
        cleaner.hintsSentence = ""
        return cleaner
    }
    private let chunkText = "Send the updated report to the team."

    @Test func batchingContiguityAndSerialCalls() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        incremental.append(index: 1, text: chunkText)
        incremental.append(index: 2, text: chunkText)
        #expect(await transport.count == 0) // Missing index zero: not cleanable.
        incremental.append(index: 0, text: chunkText)
        try await transport.wait(1)
        incremental.append(index: 3, text: chunkText)
        #expect(await transport.count == 1) // Only one new cleanable chunk.
        incremental.append(index: 4, text: chunkText)
        incremental.append(index: 5, text: chunkText)
        #expect(await transport.count == 1) // First request is still in flight.
        try await transport.respond(0, chunkText)
        try await transport.wait(2)
        #expect(await transport.count == 2)
        #expect(try await transport.user(1).contains(Array(repeating: chunkText, count: 3).joined(separator: " ")))
        try await transport.respond(1, Array(repeating: chunkText, count: 3).joined(separator: " "))
        await incremental.waitForPending()
        incremental.append(index: 6, text: chunkText)
        #expect(await transport.count == 2)
        incremental.append(index: 7, text: chunkText)
        try await transport.wait(3)
        try await transport.respond(2, chunkText + " " + chunkText)
        await incremental.waitForPending()
        incremental.append(index: 8, text: chunkText)
        #expect(await transport.count == 3)
        let finish = Task { await incremental.finish(totalChunks: 9) }
        try await transport.wait(4)
        #expect(try await transport.user(3).contains("<context>" + chunkText))
        try await transport.respond(3, Array(repeating: chunkText, count: 3).joined(separator: " "))
        let result = await finish.value
        #expect(result.mode == "incremental")
        #expect(result.calls == 4)
        #expect(await transport.maxInFlight == 1)
        for index in 0..<4 {
            let budget = try #require(try await transport.body(index)["max_completion_tokens"] as? Int)
            #expect(budget <= 1024)
        }
    }

    @Test(arguments: [1, 2]) func shortDictationUsesSinglePath(chunks: Int) async {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<chunks { incremental.append(index: index, text: chunkText) }
        let result = await incremental.finish(totalChunks: chunks)
        #expect(await transport.count == 0)
        #expect(result.mode == "single")
        #expect(result.text == nil)
    }

    @Test func finalContextAndRevisionReplaceOnlyLastSentence() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        let prefix = "Keep the deck. Meet Thursday at three."
        for (index, text) in [prefix, "No, sorry, make that Friday at four.", "Bring the slides please."].enumerated() {
            incremental.append(index: index, text: text)
        }
        try await transport.wait(1)
        try await transport.respond(0, prefix)
        await incremental.waitForPending()
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        #expect(try await transport.user(1) == "<context>\(prefix)</context>\n<dictation>No, sorry, make that Friday at four. Bring the slides please.</dictation>")
        try await transport.respond(1, "<revised>Meet Friday at four.</revised> Bring the slides please.")
        let result = await finish.value
        #expect(result.text == "Keep the deck. Meet Friday at four. Bring the slides please.")
        #expect(result.mode == "incremental")
    }

    @Test(arguments: ["<revised>Changed.</revised> Send the updated report to the team.", "<revised>broken", "x", String(repeating: "extra ", count: 50)])
    func malformedOrRejectedIntermediateFallsBack(output: String) async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        try await transport.respond(0, output)
        await incremental.waitForPending()
        #expect(incremental.needsFallback)
        incremental.append(index: 3, text: chunkText)
        let result = await incremental.finish(totalChunks: 4)
        #expect(result.mode == "incremental_fallback")
        #expect(result.text == nil)
        #expect(result.calls == 1)
    }

    @Test(arguments: [429, 200]) func errorsDisableIncremental(status: Int) async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        try await transport.respond(0, chunkText, status: status, reason: status == 200 ? "length" : "stop")
        await incremental.waitForPending()
        #expect(incremental.needsFallback)
        #expect(await incremental.finish(totalChunks: 3).mode == "incremental_fallback")
    }

    @Test func completionBudgetEveryGroqRequest() async throws {
        let transport = IncrementalTransport()
        let cleaner = cleaner(transport)
        for text in ["short text", String(repeating: "word ", count: 1000)] {
            for request in [cleaner.makeRequest(text: text, apiKey: "key"),
                            cleaner.makeIncrementalRequest(text: text, context: "Earlier sentence.", final: false, apiKey: "key"),
                            cleaner.makeIncrementalRequest(text: text, context: "Earlier sentence.", final: true, apiKey: "key")] {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let budget = try #require(body["max_completion_tokens"] as? Int)
                #expect(budget == min(1024, 2 * (text.count / 4) + 64))
            }
        }
    }

    @Test func finishWaitsForInFlightAndIsIdempotent() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        let finish = Task { await incremental.finish(totalChunks: 3) }
        #expect(await transport.count == 1)
        try await transport.respond(0, chunkText)
        try await transport.wait(2)
        #expect(await transport.maxInFlight == 1)
        #expect(try await transport.user(1).contains("<context>\(chunkText)</context>"))
        try await transport.respond(1, chunkText + " " + chunkText)
        let result = await finish.value
        #expect(result.text == Array(repeating: chunkText, count: 3).joined(separator: " "))
        #expect(await incremental.finish(totalChunks: 3).text == result.text)
        #expect(await transport.count == 2)
    }

    @Test(arguments: ["timeout", "malformed", "cancel"])
    func errorsOrCancellationPreventAnotherCall(kind: String) async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        for index in 3..<7 { incremental.append(index: index, text: chunkText) }
        if kind == "cancel" {
            incremental.cancel()
            try await transport.respond(0, chunkText)
        } else if kind == "timeout" { await transport.fail(0) }
        else { await transport.malformed(0) }
        await incremental.waitForPending()
        let result = await incremental.finish(totalChunks: 7)
        #expect(result.text == nil)
        #expect(result.calls == 1)
        #expect(await transport.count == 1)
        if kind != "cancel" { #expect(result.mode == "incremental_fallback") }
    }

    @Test(arguments: ["<revised>bad", "<revised>Changed.</revised> x", "Valid words <revised>Late.</revised>"])
    func malformedOrRatioViolatingFinalFallsBack(output: String) async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        try await transport.respond(0, chunkText)
        await incremental.waitForPending()
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        try await transport.respond(1, output)
        let result = await finish.value
        #expect(result.mode == "incremental_fallback")
        #expect(result.text == nil)
        #expect(result.calls == 2)
    }

    @Test func simpleSentenceJoinAndContextCap() {
        #expect(IncrementalCleaner.join(prefix: "First? Last!", revision: "Changed!", tail: " Next.\n") == "First? Changed! Next.")
        #expect(IncrementalCleaner.join(prefix: "No sentence boundary", revision: "Replacement.", tail: "Tail.") == "Replacement. Tail.")
        #expect(IncrementalCleaner.join(prefix: "Keep. Last", revision: "Changed.", tail: "") == "Keep. Changed.")
        let request = cleaner(IncrementalTransport()).makeIncrementalRequest(text: chunkText,
            context: String(repeating: "x", count: 700), final: true, apiKey: "key")
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let user = (body["messages"] as! [[String: String]]).last!["content"]!
        #expect(user.contains("<context>" + String(repeating: "x", count: 600) + "</context>"))
    }
}
