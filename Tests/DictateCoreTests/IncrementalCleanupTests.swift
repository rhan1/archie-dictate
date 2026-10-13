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

private actor RaceIncrementalTransport: HTTPTransport {
    let midMs: Int
    private let clock: (any DictateClock)?
    private var count = 0
    private var started = false
    private var cancelled = false
    private var anchorAt: ContinuousClock.Instant?
    init(midMs: Int, clock: (any DictateClock)? = nil) {
        self.midMs = midMs
        self.clock = clock
    }
    func anchor(_ instant: ContinuousClock.Instant) { anchorAt = instant }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let mid = count == 1
        started = true
        // The mid call's delay counts from the test's finish() anchor, not from its own start,
        // so suite load between start and finish cannot shrink the race margin.
        do {
            if mid {
                if let clock {
                    while anchorAt == nil { try await Task.sleep(for: .milliseconds(1)) }
                    try await clock.sleep(until: anchorAt!.advanced(by: .milliseconds(midMs)))
                } else {
                    while anchorAt == nil { try await Task.sleep(for: .milliseconds(1)) }
                    try await Task.sleep(until: anchorAt! + .milliseconds(midMs))
                }
            } else { try await Task.sleep(for: .milliseconds(1)) }
        } catch { cancelled = true; throw error }
        let content = mid ? "Send the updated report to the team." :
            "Send the updated report to the team. Send the updated report to the team. Send the updated report to the team."
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        return (data, HTTPURLResponse(url: TranscriptCleaner.groqEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func waitForStart() async throws {
        for _ in 0..<500 {
            if started { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    func waitForCancellation() async throws {
        for _ in 0..<200 {
            if cancelled { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(cancelled)
    }
}

private actor SingleProbe {
    let delayMs: Int
    private let clock: (any DictateClock)?
    private(set) var startedAt: ContinuousClock.Instant?
    private(set) var startedAtElapsed: Duration?
    private(set) var raw: String?
    private var cancelled = false
    init(delayMs: Int, clock: (any DictateClock)? = nil) {
        self.delayMs = delayMs
        self.clock = clock
    }
    func clean(_ text: String) async -> IncrementalCleaner.SingleResult {
        raw = text
        startedAt = clock?.now() ?? .now
        startedAtElapsed = (clock as? ManualClock)?.elapsed ?? .zero
        do {
            if delayMs > 0 {
                if let clock {
                    try await clock.sleep(until: clock.now().advanced(by: .milliseconds(delayMs)))
                } else {
                    try await Task.sleep(for: .milliseconds(delayMs))
                }
            }
        }
        catch { cancelled = true }
        return .init(text: "Single winner.", label: "ok", model: "fake", stats: nil, calls: 1)
    }
    func waitForCancellation() async throws {
        for _ in 0..<200 {
            if cancelled { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(cancelled)
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

    @Test func shortPromptOnlyAtFinal() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport), finalIncludeExamples: false)
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        #expect(try await (transport.body(0)["messages"] as! [[String: String]]).count == 2)
        try await transport.respond(0, chunkText)
        await incremental.waitForPending()
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        #expect(try await (transport.body(1)["messages"] as! [[String: String]]).count == 2)
        try await transport.respond(1, Array(repeating: chunkText, count: 3).joined(separator: " "))
        #expect(await finish.value.mode == "incremental")
    }

    @Test func midCallPromptUnder400TokensAndOmitsFewShot() throws {
        let transport = IncrementalTransport()
        let cl = TranscriptCleaner(transport: transport, vocabulary: "Kubernetes, PostgreSQL, Acme Corp", apiKey: { "hermetic-key" })
        let sample200 = String(repeating: "a", count: 200)
        let request = cl.makeIncrementalRequest(text: sample200, context: "Some preceding context.", final: false, apiKey: "key")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        #expect(messages.count == 2)
        let totalChars = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
        let tokensDiv4 = Double(totalChars) / 4.0
        #expect(tokensDiv4 <= 400.0)
    }

    @Test(arguments: [true, false]) func raceStartsSingleAfter600AndFirstWins(singleWins: Bool) async throws {
        let manual = ManualClock()
        let transport = RaceIncrementalTransport(midMs: singleWins ? 1_000 : 640, clock: manual)
        let incremental = IncrementalCleaner(cleaner: TranscriptCleaner(
            transport: transport, vocabulary: "", apiKey: { "hermetic-key" }), clock: manual)
        incremental.append(index: 0, text: chunkText)
        incremental.append(index: 1, text: chunkText)
        try await transport.waitForStart()
        incremental.seal()
        incremental.append(index: 2, text: chunkText)
        let single = SingleProbe(delayMs: singleWins ? 5 : 1_000, clock: manual)
        let start = manual.now()
        await transport.anchor(start)
        let finishTask = Task {
            await incremental.finish(totalChunks: 3, rawText: chunkText + " " + chunkText + " " + chunkText,
                single: { raw in await single.clean(raw) })
        }
        #expect(await manual.waitForSleepers(2))
        manual.advance(by: .milliseconds(599))
        #expect(await single.startedAtElapsed == nil)
        manual.advance(by: .milliseconds(1))
        #expect(await manual.waitForSleepers(2))
        manual.advance(by: .milliseconds(singleWins ? 10 : 50))
        let result = await finishTask.value
        #expect(result.mode == (singleWins ? "race_single" : "race_incremental"))
        #expect(result.text == (singleWins ? "Single winner." : "Send the updated report to the team. Send the updated report to the team. Send the updated report to the team."))
        #expect(result.calls == (singleWins ? 2 : 3))
        #expect(result.fallbackReason == "mid_slow_at_finish")
        #expect(manual.elapsed < .milliseconds(850))
        let delay = try #require(await single.startedAtElapsed)
        #expect(delay >= .milliseconds(600) && delay < .milliseconds(650))
        #expect(await single.raw == chunkText + " " + chunkText + " " + chunkText)
        if singleWins { try await transport.waitForCancellation() }
        else { try await single.waitForCancellation() }
    }

    @Test func failedMidStartsSingleImmediately() async throws {
        let manual = ManualClock()
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport), raceAfterMs: 30, clock: manual)
        for index in 0..<2 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        await transport.fail(0)
        await incremental.waitForPending()
        incremental.seal()
        incremental.append(index: 2, text: chunkText)
        let single = SingleProbe(delayMs: 0, clock: manual)
        var singleStartedAtElapsed: Duration?
        let result = await incremental.finish(totalChunks: 3, rawText: "full raw fixture",
            single: { raw in
                singleStartedAtElapsed = manual.elapsed
                return await single.clean(raw)
            })
        #expect(singleStartedAtElapsed == .zero)
        #expect(result.mode == "incremental_fallback")
        #expect(result.fallbackReason == "mid_network_timedOut")
        #expect(result.text == "Single winner.")
        #expect(result.calls == 2)
        #expect(await single.raw == "full raw fixture")
    }

    @Test func threeChunksUseIncremental() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        incremental.append(index: 0, text: "Keep this. Last sentence.")
        incremental.append(index: 1, text: "Tail one.")
        try await transport.wait(1)
        #expect(try await transport.user(0) == "<context></context>\n<dictation>Keep this. Last sentence.</dictation>")
        incremental.seal()
        incremental.append(index: 2, text: "Tail two.")
        try await transport.respond(0, "Keep this. Last sentence.")
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        #expect(try await transport.user(1) == "<context>Keep this.</context>\n<dictation>Last sentence. Tail one. Tail two.</dictation>")
        try await transport.respond(1, "Last sentence. Tail one. Tail two.")
        let result = await finish.value
        #expect(result.mode == "incremental")
        #expect(result.calls == 2)
        #expect(result.text == "Keep this. Last sentence. Tail one. Tail two.")
        #expect(result.skippedReason == nil)
    }

    @Test func skipReasonLogged() async {
        for total in [2, 3] {
            let incremental = IncrementalCleaner(cleaner: cleaner(IncrementalTransport()))
            incremental.seal()
            for index in 0..<total { incremental.append(index: index, text: chunkText) }
            let result = await incremental.finish(totalChunks: total)
            #expect(result.mode == "single")
            #expect(result.skippedReason == (total == 2 ? "short" : "none_cleanable_before_finish"))
            var entry = DictationLogEntry(time: Date(), durationSeconds: 1, audioBytes: 0,
                latencyMs: 0, chars: 0, frontmostBundleID: "test", outcome: .ok)
            entry.cleanupMode = result.mode
            entry.incrementalSkipped = result.skippedReason
            #expect(entry.formatted().contains("incremental_skipped=" + result.skippedReason!))
        }
    }

    @Test func replacementOfUncleanedChunksOverwritesRaw() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        incremental.append(index: 0, text: chunkText)
        incremental.append(index: 1, text: "and,")
        try await transport.wait(1)
        try await transport.respond(0, chunkText)
        await incremental.waitForPending()
        incremental.seal()
        incremental.append(index: 2, text: "other screenshots.")
        incremental.append(index: 1, text: "and, uh, the screenshots.")  // rejoin: joined text on index-1, "" on index
        incremental.append(index: 2, text: "")
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        #expect(try await transport.user(1) == "<context></context>\n<dictation>" + chunkText + " and, uh, the screenshots.</dictation>")
        try await transport.respond(1, chunkText + " and, uh, the screenshots.")
        let result = await finish.value
        #expect(result.mode == "incremental")
        #expect(result.text == chunkText + " and, uh, the screenshots.")
    }

    @Test(arguments: [true, false]) func replacementOfCleanedChunkForcesFullRawSingle(midDone: Bool) async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        incremental.append(index: 1, text: "and,")
        incremental.append(index: 2, text: chunkText)
        incremental.append(index: 0, text: chunkText)   // contiguous 3: the mid batch covers chunks 0 and 1
        try await transport.wait(1)
        if midDone {
            try await transport.respond(0, chunkText + " and,")
            await incremental.waitForPending()
        }
        incremental.seal()
        incremental.append(index: 1, text: "and, uh, the screenshots.")
        incremental.append(index: 2, text: "")
        if !midDone { try await transport.respond(0, chunkText + " and,") }  // stale result must be ignored
        let single = SingleProbe(delayMs: 0)
        let result = await incremental.finish(totalChunks: 3, rawText: "FULL RAW", single: { raw in await single.clean(raw) })
        #expect(result.mode == "single")
        #expect(result.skippedReason == "rejoin_replaced")
        #expect(result.text == "Single winner.")
        #expect(await single.raw == "FULL RAW")
        #expect(await transport.count == 1)  // no final tail call from the stale prefix
        #expect(incremental.needsFallback == false)
    }

    @Test func finishAfterFailedMidIsImmediate() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        await transport.fail(0)
        await incremental.waitForPending()
        let start = ContinuousClock.now
        let result = await incremental.finish(totalChunks: 3)
        // Proves no wait for the 600 ms race; the margin absorbs suite load.
        #expect(start.duration(to: .now) < .milliseconds(300))
        #expect(result.mode == "incremental_fallback")
        #expect(result.fallbackReason == "mid_network_timedOut")
        #expect(result.calls == 1)
        #expect(await transport.count == 1)
    }

    @Test func batchingContiguityAndSerialCalls() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        incremental.append(index: 1, text: chunkText)
        incremental.append(index: 2, text: chunkText)
        #expect(await transport.count == 0) // Missing index zero: not cleanable.
        incremental.append(index: 0, text: chunkText)
        try await transport.wait(1)
        #expect(try await transport.user(0) == "<context></context>\n<dictation>\(chunkText) \(chunkText)</dictation>")
        incremental.append(index: 3, text: chunkText)
        #expect(await transport.count == 1) // Only one new cleanable chunk.
        incremental.append(index: 4, text: chunkText)
        incremental.append(index: 5, text: chunkText)
        #expect(await transport.count == 1) // First request is still in flight.
        try await transport.respond(0, chunkText + " " + chunkText)
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

    /// Live 05:26: the last chunk's text lands AFTER the finish tap; it must not
    /// start another intermediate call that the final tail call then waits for.
    @Test func sealAtFinishTapStopsNewIntermediateCalls() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        try await transport.respond(0, chunkText)
        await incremental.waitForPending()
        incremental.seal()                                   // finish tap
        incremental.append(index: 3, text: chunkText)
        incremental.append(index: 4, text: chunkText)
        incremental.append(index: 5, text: chunkText)
        #expect(await transport.count == 1)                  // no new intermediate call
        let finish = Task { await incremental.finish(totalChunks: 6) }
        try await transport.wait(2)
        #expect(await transport.count == 2)                  // straight to the final call
        try await transport.respond(1, Array(repeating: chunkText, count: 5).joined(separator: " "))
        let result = await finish.value
        #expect(result.mode == "incremental")
        #expect(result.calls == 2)
    }

    /// v1.6 D7: both intermediate and final calls omit few-shot pairs.
    @Test func midAndFinalCallsOmitFewShotByDefault() async throws {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        for index in 0..<3 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        try await transport.respond(0, chunkText)
        await incremental.waitForPending()
        incremental.seal()
        let finish = Task { await incremental.finish(totalChunks: 3) }
        try await transport.wait(2)
        let intermediate = try await transport.body(0)["messages"] as! [[String: String]]
        let final = try await transport.body(1)["messages"] as! [[String: String]]
        #expect(intermediate.count == 2)
        #expect(final.count == 2)
        try await transport.respond(1, Array(repeating: chunkText, count: 2).joined(separator: " "))
        _ = await finish.value
    }

    @Test(arguments: [1, 2]) func shortDictationUsesSinglePath(chunks: Int) async {
        let transport = IncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport))
        incremental.seal()
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

    @Test func tpmBudgetSkipsMidsAndSpendsOneFinalCallWithoutFewShot() async throws {
        let transport = IncrementalTransport()
        let cl = cleaner(transport)
        let response = HTTPURLResponse(
            url: TranscriptCleaner.groqEndpoint, statusCode: 200, httpVersion: nil,
            headerFields: [
                "x-ratelimit-remaining-tokens": "500",
                "x-ratelimit-reset-tokens": "30s",
                "x-ratelimit-limit-tokens": "8000",
            ]
        )!
        let quota = GroqQuota().merging(GroqRateLimit(response: response, endpoint: .cleanup), at: Date())
        let incremental = IncrementalCleaner(cleaner: cl, quotaProvider: { quota })

        incremental.append(index: 0, text: "Chunk zero.")
        incremental.append(index: 1, text: "Chunk one.")
        incremental.append(index: 2, text: "Chunk two.")

        try await Task.sleep(nanoseconds: 10_000_000)
        let countBeforeFinish = await transport.count
        #expect(countBeforeFinish == 0)

        let finishTask = Task {
            await incremental.finish(totalChunks: 3, rawText: "Chunk zero. Chunk one. Chunk two.")
        }

        try await transport.wait(1)
        let countAfterFinish = await transport.count
        #expect(countAfterFinish == 1)

        let body = try await transport.body(0)
        let messages = body["messages"] as? [[String: String]] ?? []
        #expect(messages.count == 2)

        try await transport.respond(0, "Cleaned full sentence.")
        let result = await finishTask.value

        #expect(result.mode == "single")
        #expect(result.skippedReason == "tpm")
        #expect(result.calls == 1)
        #expect(result.text == "Cleaned full sentence.")
    }

    @Test func tpmBudgetWithSinglePathUsesFewShotFreeFinalCall() async throws {
        let transport = IncrementalTransport()
        let cl = cleaner(transport)
        let response = HTTPURLResponse(
            url: TranscriptCleaner.groqEndpoint, statusCode: 200, httpVersion: nil,
            headerFields: [
                "x-ratelimit-remaining-tokens": "500",
                "x-ratelimit-reset-tokens": "30s",
                "x-ratelimit-limit-tokens": "8000",
            ]
        )!
        let quota = GroqQuota().merging(GroqRateLimit(response: response, endpoint: .cleanup), at: Date())
        let incremental = IncrementalCleaner(cleaner: cl, quotaProvider: { quota })

        incremental.append(index: 0, text: "Chunk zero.")
        incremental.append(index: 1, text: "Chunk one.")
        incremental.append(index: 2, text: "Chunk two.")

        try await Task.sleep(nanoseconds: 10_000_000)
        let countBeforeFinish = await transport.count
        #expect(countBeforeFinish == 0)

        let finishTask = Task {
            await incremental.finish(totalChunks: 3, rawText: "Chunk zero. Chunk one. Chunk two.",
                                     single: { _ in
                                         .init(text: "From single probe", label: "ok", model: "fake", stats: nil, calls: 1)
                                     })
        }

        try await transport.wait(1)
        let countAfterFinish = await transport.count
        #expect(countAfterFinish == 1)
        let body = try await transport.body(0)
        let messages = body["messages"] as? [[String: String]] ?? []
        #expect(messages.count == 2)

        try await transport.respond(0, "Cleaned full sentence.")
        let result = await finishTask.value

        #expect(result.mode == "single")
        #expect(result.skippedReason == "tpm")
        #expect(result.calls == 1)
        #expect(result.text == "Cleaned full sentence.")
    }

    @Test func tpmSufficientTokensDoesNotSkipMids() async throws {
        let transport = IncrementalTransport()
        let cl = cleaner(transport)
        let response = HTTPURLResponse(
            url: TranscriptCleaner.groqEndpoint, statusCode: 200, httpVersion: nil,
            headerFields: [
                "x-ratelimit-remaining-tokens": "5000",
                "x-ratelimit-reset-tokens": "30s",
                "x-ratelimit-limit-tokens": "8000",
            ]
        )!
        let quota = GroqQuota().merging(GroqRateLimit(response: response, endpoint: .cleanup), at: Date())
        let incremental = IncrementalCleaner(cleaner: cl, quotaProvider: { quota })

        incremental.append(index: 0, text: "Chunk zero.")
        incremental.append(index: 1, text: "Chunk one.")

        try await transport.wait(1)
        let count = await transport.count
        #expect(count == 1)
    }
}

