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

    @Test func finalReCleansLastSentence() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        let prefix = "Let's meet on Thursday at three."
        for (index, text) in [prefix, "no sorry make that Friday at four", ""].enumerated() {
            incremental.append(index: index, text: text)
        }
        try await transport.wait(1)
        try await transport.respond(0, prefix)
        await incremental.waitForPending()
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        #expect(try await transport.user(1) == "<context></context>\n<dictation>Let's meet on Thursday at three. no sorry make that Friday at four</dictation>")
        try await transport.respond(1, "Let's meet on Friday at four.")
        let result = await finish.value
        #expect(result.text == "Let's meet on Friday at four.")
        #expect(result.text?.contains("Thursday") == false)
        #expect(result.mode == "incremental")
        #expect(result.fallbackReason == nil)
    }

    @Test func finalCompletesQuestion() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        let prefix = "What time is the Politrace"
        for (index, text) in [prefix, "review", "tomorrow"].enumerated() {
            incremental.append(index: index, text: text)
        }
        try await transport.wait(1)
        try await transport.respond(0, prefix)
        await incremental.waitForPending()
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        #expect(try await transport.user(1) == "<context></context>\n<dictation>What time is the Politrace review tomorrow</dictation>")
        try await transport.respond(1, "What time is the Politrace review tomorrow?")
        let result = await finish.value
        #expect(result.mode == "incremental")
        #expect(result.text == "What time is the Politrace review tomorrow?")
        #expect(result.text?.hasSuffix("?") == true)
    }

    @Test func finalPreservesEarlierSentencesAndCapsContext() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        let earlier = String(repeating: "Keep the deck. ", count: 50).trimmingCharacters(in: .whitespaces)
        let prefix = earlier + " Let's meet on Thursday at three."
        for (index, text) in [prefix, "no sorry make that Friday at four", ""].enumerated() {
            incremental.append(index: index, text: text)
        }
        try await transport.wait(1)
        try await transport.respond(0, prefix)
        await incremental.waitForPending()
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        #expect(try await transport.user(1) == "<context>\(String(earlier.suffix(600)))</context>\n<dictation>Let's meet on Thursday at three. no sorry make that Friday at four</dictation>")
        try await transport.respond(1, "Let's meet on Friday at four.")
        let result = await finish.value
        #expect(result.text == earlier + " Let's meet on Friday at four.")
        #expect(result.mode == "incremental")
    }

    @Test func finalOversizedOutputRejectedByCombinedRatio() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        let lastSentence = "Meet Thursday at three."
        let prefix = "Keep the deck. " + lastSentence
        let rawTail = "Bring the updated slides to the review meeting."
        for (index, text) in [prefix, rawTail, ""].enumerated() {
            incremental.append(index: index, text: text)
        }
        try await transport.wait(1)
        try await transport.respond(0, prefix)
        await incremental.waitForPending()
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        let oversized = Array(repeating: lastSentence + " " + rawTail, count: 3).joined(separator: " ")
        try await transport.respond(1, oversized)
        let result = await finish.value
        #expect(result.mode == "incremental_fallback")
        #expect(result.text == nil)
        #expect(result.fallbackReason == "final_rejected_ratio")
    }

    @Test func joinDropsRepeatedBoundaryWords() {
        #expect(IncrementalCleaner.join(prefix: "Is", tail: "Is TurnoutWatch still up?") == "Is TurnoutWatch still up?")
        #expect(IncrementalCleaner.join(prefix: "Earlier. IS,", tail: "is TurnoutWatch still up?") == "Earlier. IS, TurnoutWatch still up?")
        #expect(IncrementalCleaner.join(prefix: "Earlier. Is TurnoutWatch", tail: "is turnoutwatch still up?") == "Earlier. Is TurnoutWatch still up?")
        #expect(IncrementalCleaner.join(prefix: "Earlier. Is TurnoutWatch still", tail: "IS TurnoutWatch still up?") == "Earlier. Is TurnoutWatch still up?")
        #expect(IncrementalCleaner.join(prefix: "Earlier. Is TurnoutWatch", tail: "Will TurnoutWatch stay up?") == "Earlier. Is TurnoutWatch Will TurnoutWatch stay up?")
        #expect(IncrementalCleaner.join(prefix: "Earlier. Go go", tail: "go go now.") == "Earlier. Go go now.")
    }

    @Test(arguments: ["<output>Changed.</output> Send the updated report to the team.", "<output>broken", "x", String(repeating: "extra ", count: 50)])
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
        #expect(try await transport.user(1).contains("<context></context>\n<dictation>\(chunkText) \(chunkText) \(chunkText)</dictation>"))
        try await transport.respond(1, Array(repeating: chunkText, count: 3).joined(separator: " "))
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

    @Test(arguments: ["<output>bad", "<output>Changed.</output> x", "Valid words <output>Late.</output>", "x"])
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

    @Test func incrementalInstructionsProtectUnfinishedFragments() throws {
        let cleaner = cleaner(IncrementalTransport())
        for final in [false, true] {
            let request = cleaner.makeIncrementalRequest(text: chunkText, context: "Earlier.", final: final, apiKey: "key")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            let system = messages[0]["content"]!
            if final {
                #expect(system.contains("The start of <dictation> is already cleaned; keep it unless the rest of the dictation corrects, retracts, continues or completes it"))
            } else {
                #expect(system.contains("If the dictation ends mid-sentence, do not add final punctuation to that unfinished fragment."))
            }
        }
    }

    @Test func simpleSentenceJoinAndContextCap() {
        #expect(IncrementalCleaner.lastSentence("First? Last!") == "Last!")
        #expect(IncrementalCleaner.lastSentence("No sentence boundary") == "No sentence boundary")
        #expect(IncrementalCleaner.lastSentence("Keep. Last") == "Last")
        #expect(IncrementalCleaner.lastSentence("Keep. Visit www.blog.com.au") == "Visit www.blog.com.au")
        #expect(IncrementalCleaner.join(prefix: "First? Last!", tail: " Next.\n") == "First? Last! Next.")
        #expect(IncrementalCleaner.join(prefix: "", tail: "Tail.") == "Tail.")
        #expect(IncrementalCleaner.join(prefix: "Keep.", tail: "") == "Keep.")
        let request = cleaner(IncrementalTransport()).makeIncrementalRequest(text: chunkText,
            context: String(repeating: "x", count: 700), final: true, apiKey: "key")
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let user = (body["messages"] as! [[String: String]]).last!["content"]!
        #expect(user.contains("<context>" + String(repeating: "x", count: 600) + "</context>"))
    }
}
