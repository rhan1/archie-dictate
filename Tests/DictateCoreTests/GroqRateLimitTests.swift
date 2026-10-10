import Foundation
import Testing
import DictateCore

private final class LimitObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GroqRateLimit] = []
    func append(_ value: GroqRateLimit) { lock.withLock { values.append(value) } }
    var all: [GroqRateLimit] { lock.withLock { values } }
}

private actor LimitTransport: HTTPTransport {
    let status: Int
    let text: String
    let headers: [String: String]
    private(set) var requests: [URLRequest] = []
    init(status: Int = 200, text: String = "please send the whole report tomorrow", headers: [String: String] = [:]) {
        self.status = status; self.text = text; self.headers = headers
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let payload: [String: Any] = request.url!.path.contains("transcriptions") ? ["text": text] :
            ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

/// Keeps both hedge responses alive after cancellation to test late losers too.
private actor LimitHedgeTransport: HTTPTransport {
    private var pending: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    private(set) var count = 0
    private var urls: [Int: URL] = [:]
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let index = count
        urls[index] = request.url!
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func waitFor(_ count: Int) async throws {
        for _ in 0..<2000 {
            if self.count >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw URLError(.timedOut)
    }
    func respond(_ index: Int, status: Int, remaining: Int) throws {
        let item = pending.removeValue(forKey: index)
        let continuation = try #require(item)
        let url = urls[index]!
        let data = url.path.contains("transcriptions") ? Data(#"{"text":"hello"}"#.utf8) :
            Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"please send the whole report tomorrow"}}]}"#.utf8)
        continuation.resume(returning: (data, HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["x-ratelimit-remaining-requests": String(remaining)])!))
    }
}

@Suite("GroqRateLimitTests")
struct GroqRateLimitTests {
    @Test func parsesCountsCaseInsensitively() {
        let response = HTTPURLResponse(url: TranscriptionClient.groqEndpoint, statusCode: 429, httpVersion: nil,
            headerFields: ["X-RateLimit-Limit-Requests": "100", "x-ratelimit-remaining-requests": "0",
                           "x-ratelimit-limit-tokens": " 200 ", "x-ratelimit-remaining-tokens": "12"])!
        let limits = GroqRateLimit(response: response, endpoint: .stt)
        #expect(limits.limitRequests == 100)
        #expect(limits.remainingRequests == 0)
        #expect(limits.limitTokens == 200)
        #expect(limits.remainingTokens == 12)
        #expect(limits.endpoint == .stt)
    }
    @Test func absentAndInvalidFieldsAreNil() {
        for headers in [[:], ["x-ratelimit-limit-requests": "bad", "x-ratelimit-remaining-requests": "-1",
            "x-ratelimit-limit-tokens": "1.5", "x-ratelimit-remaining-tokens": "9999999999999999999999999"],
            ["x-ratelimit-limit-requests": "", "x-ratelimit-remaining-requests": "+1",
             "x-ratelimit-limit-tokens": "١", "x-ratelimit-remaining-tokens": "1e2"]] {
            let limits = GroqRateLimit(response: HTTPURLResponse(url: TranscriptCleaner.groqEndpoint,
                statusCode: 200, httpVersion: nil, headerFields: headers)!, endpoint: .cleanup)
            #expect(limits.limitRequests == nil && limits.remainingRequests == nil)
            #expect(limits.limitTokens == nil && limits.remainingTokens == nil)
            #expect(limits.endpoint == .cleanup)
        }
    }
    @Test func sttSuccessAndFailureBothNotify() async {
        for status in [200, 429] {
            let seen = LimitObservations()
            let transport = LimitTransport(status: status, headers: ["x-ratelimit-remaining-tokens": "9"])
            let stt = GroqChunkedTranscriber(transport: transport, apiKey: { "fixture" }, prompt: "",
                fillerLeadIn: false, hedgeAfterMs: 700, onGroqRateLimit: { seen.append($0) })
            stt.submit(.init(index: 0, samples: [100, 200]))
            _ = await stt.finish()
            let expectedCalls = status == 200 ? 1 : 2 // Existing failed-chunk retry is unchanged.
            #expect(await transport.requests.count == expectedCalls)
            #expect(seen.all.count == expectedCalls)
            #expect(seen.all.first?.remainingTokens == 9)
            #expect(seen.all.first?.endpoint == .stt)
        }
    }
    @Test func observesHedgeWinnerAndLateLoser() async throws {
        let seen = LimitObservations()
        let transport = LimitHedgeTransport()
        let stt = GroqChunkedTranscriber(transport: transport, apiKey: { "fixture" }, prompt: "", fillerLeadIn: false,
            hedgeAfterMs: 1, onGroqRateLimit: { seen.append($0) })
        stt.submit(.init(index: 0, samples: [100, 200]))
        let finish = Task { await stt.finish() }
        try await transport.waitFor(2)
        try await transport.respond(2, status: 200, remaining: 8)
        let result = await finish.value
        #expect(result.hedges == 1 && result.hedgeWins == 1)
        try await transport.respond(1, status: 429, remaining: 7)
        for _ in 0..<2000 {
            if seen.all.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(seen.all.map(\.remainingRequests) == [8, 7])
    }
    @Test func cleanupSingleIncrementalFinalWarmAndErrorsNotify() async throws {
        let seen = LimitObservations()
        let transport = LimitTransport(headers: ["x-ratelimit-limit-tokens": "1000"])
        let cleaner = TranscriptCleaner(transport: transport, vocabulary: "", apiKey: { "fixture" },
                                        onGroqRateLimit: { seen.append($0) })
        let raw = "please send the whole report tomorrow"
        _ = try await cleaner.cleanWithStats(raw)
        _ = try await cleaner.cleanIncrementalWithStats(raw, context: "", final: false)
        _ = try await cleaner.cleanIncrementalWithStats(raw, context: "", final: true)
        await cleaner.warmUp()
        #expect(await transport.requests.count == 4)
        #expect(seen.all.count == 4)
        #expect(seen.all.allSatisfy { $0.endpoint == .cleanup && $0.limitTokens == 1000 })
        let failed = TranscriptCleaner(transport: LimitTransport(status: 429), vocabulary: "", apiKey: { "fixture" },
                                       onGroqRateLimit: { seen.append($0) })
        do { _ = try await failed.clean(raw); Issue.record("429 must fail") } catch {}
        do { _ = try await failed.cleanIncrementalWithStats(raw, context: "", final: true); Issue.record("429 must fail") } catch {}
        #expect(seen.all.count == 6)
    }
    @Test func cleanupRaceAndLateIntermediateBothNotify() async throws {
        let seen = LimitObservations()
        let transport = LimitHedgeTransport()
        let cleaner = TranscriptCleaner(transport: transport, vocabulary: "", apiKey: { "fixture" },
                                        onGroqRateLimit: { seen.append($0) })
        let raw = "please send the whole report tomorrow"
        let incremental = IncrementalCleaner(cleaner: cleaner, raceAfterMs: 0)
        incremental.append(index: 0, text: raw)
        incremental.append(index: 1, text: raw)
        incremental.append(index: 2, text: raw)
        try await transport.waitFor(1)
        incremental.seal()
        let finish = Task {
            await incremental.finish(totalChunks: 3, rawText: raw, single: { text in
                let output = try? await cleaner.cleanWithStats(text)
                return .init(text: output?.text ?? text, label: "ok", model: cleaner.model, stats: output?.stats, calls: 1)
            })
        }
        try await transport.waitFor(2)
        try await transport.respond(2, status: 200, remaining: 8)
        let result = await finish.value
        #expect(result.mode == "race_single" && result.calls == 2)
        try await transport.respond(1, status: 200, remaining: 7)
        for _ in 0..<2000 {
            if seen.all.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(seen.all.map(\.remainingRequests) == [8, 7])
        #expect(seen.all.allSatisfy { $0.endpoint == .cleanup })
    }
    @Test func localCallsNeverNotifyGroqObserver() async throws {
        let seen = LimitObservations()
        let transport = LimitTransport()
        let local = TranscriptCleaner(transport: transport, endpoint: TranscriptCleaner.ollamaEndpoint,
            vocabulary: "", apiKey: { "ollama" }, onGroqRateLimit: { seen.append($0) })
        _ = try await local.clean("please send the whole report tomorrow")
        await local.warmUp()
        #expect(await transport.requests.count == 2)
        #expect(seen.all.isEmpty)
    }
    @Test func incrementalCleanerPreservesObserverOnCopiedCleaner() async {
        let seen = LimitObservations()
        let transport = LimitTransport(text: "please send the whole report tomorrow")
        let cleaner = TranscriptCleaner(transport: transport, vocabulary: "", apiKey: { "fixture" },
                                        onGroqRateLimit: { seen.append($0) })
        let incremental = IncrementalCleaner(cleaner: cleaner)
        incremental.append(index: 0, text: "please send the whole report tomorrow")
        incremental.append(index: 1, text: "please send the whole report tomorrow")
        await incremental.waitForPending()
        incremental.append(index: 2, text: "please send the whole report tomorrow")
        _ = await incremental.finish(totalChunks: 3)
        #expect(await transport.requests.count == 2)
        #expect(seen.all.count == 2)
    }
}
