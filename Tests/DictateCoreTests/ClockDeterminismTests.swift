import Foundation
import Testing
import DictateCore

// MARK: - Helpers

private actor StallIncrementalTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
        }
    }
    func wait(_ count: Int) async throws {
        for _ in 0..<2000 {
            if requests.count >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw URLError(.timedOut)
    }
    func fail(_ index: Int) {
        pending.removeValue(forKey: index)!.resume(throwing: URLError(.timedOut))
    }
}

private actor StallRaceTransport: HTTPTransport {
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
        do {
            if mid {
                if let clock {
                    while anchorAt == nil { try await Task.sleep(for: .milliseconds(1)) }
                    try await clock.sleep(until: anchorAt!.advanced(by: .milliseconds(midMs)))
                } else {
                    while anchorAt == nil { try await Task.sleep(for: .milliseconds(1)) }
                    try await Task.sleep(until: anchorAt! + .milliseconds(midMs))
                }
            } else {
                try await Task.sleep(for: .milliseconds(1))
            }
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

private actor StallSingleProbe {
    let delayMs: Int
    let stallMs: Int
    private let clock: (any DictateClock)?
    private(set) var startedAt: ContinuousClock.Instant?
    private(set) var startedAtElapsed: Duration?
    private(set) var raw: String?
    private var cancelled = false

    init(delayMs: Int, stallMs: Int = 0, clock: (any DictateClock)? = nil) {
        self.delayMs = delayMs
        self.stallMs = stallMs
        self.clock = clock
    }
    func clean(_ text: String) async -> IncrementalCleaner.SingleResult {
        raw = text
        startedAt = clock?.now() ?? .now
        startedAtElapsed = (clock as? ManualClock)?.elapsed ?? .zero
        if stallMs > 0 {
            try? await Task.sleep(for: .milliseconds(stallMs))
        }
        do {
            if delayMs > 0 {
                if let clock {
                    try await clock.sleep(until: clock.now().advanced(by: .milliseconds(delayMs)))
                } else {
                    try await Task.sleep(for: .milliseconds(delayMs))
                }
            }
        } catch { cancelled = true }
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

private actor StallHedgeTransport: HTTPTransport {
    private let clock: (any DictateClock)?
    let stallMs: Int
    private(set) var requests: [URLRequest] = []
    private(set) var requestTimes: [Duration] = []
    private(set) var cancelled: Set<Int> = []

    init(stallMs: Int = 0, clock: (any DictateClock)? = nil) {
        self.stallMs = stallMs
        self.clock = clock
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let number = requests.count + 1
        requests.append(request)
        if let manual = clock as? ManualClock {
            requestTimes.append(manual.elapsed)
        }
        let delay = number == 1 ? 2_000 : 1
        if number == 2 && stallMs > 0 {
            try? await Task.sleep(for: .milliseconds(stallMs))
        }
        do {
            if let clock {
                try await clock.sleep(until: clock.now().advanced(by: .milliseconds(delay)))
            } else {
                try await Task.sleep(for: .milliseconds(delay))
            }
        } catch {
            cancelled.insert(number)
            throw error
        }
        let data = try JSONSerialization.data(withJSONObject: ["text": number == 1 ? "primary" : "duplicate"])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func waitForCancellation(_ number: Int) async throws {
        for _ in 0..<200 {
            if cancelled.contains(number) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(cancelled.contains(number))
    }
}

// MARK: - Test Suite

@Suite("ClockDeterminism")
struct ClockDeterminismTests {
    private let chunkText = "Send the updated report to the team."

    private func cleaner(_ transport: HTTPTransport) -> TranscriptCleaner {
        var cleaner = TranscriptCleaner(transport: transport, vocabulary: "", apiKey: { "hermetic-key" })
        cleaner.hintsSentence = ""
        return cleaner
    }

    private func chunk(_ index: Int, tag: Int16) -> PauseChunker.Chunk {
        .init(index: index, samples: [Int16](repeating: tag, count: 2_400))
    }

    // MARK: - (a) failedMidStartsSingleImmediately: 150 ms bound with 200 ms stall

    // Stalled by 200 ms on a 150 ms bound: breaks the wall-clock bound deterministically.
    @Test func failedMidStartsSingleImmediatelyRealClockUnderStallRed() async throws {
        let transport = StallIncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport), raceAfterMs: 30)
        for index in 0..<2 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        await transport.fail(0)
        await incremental.waitForPending()
        incremental.seal()
        incremental.append(index: 2, text: chunkText)
        let single = StallSingleProbe(delayMs: 1, stallMs: 200)
        let start = ContinuousClock.now
        let result = await incremental.finish(totalChunks: 3, rawText: "full raw fixture",
            single: { raw in await single.clean(raw) })
        withKnownIssue("real clock under a 200 ms stall breaks the wall-clock bound") {
            #expect(start.duration(to: .now) < .milliseconds(150))
        }
        #expect(result.mode == "incremental_fallback")
        #expect(result.fallbackReason == "mid_network_timedOut")
        #expect(result.text == "Single winner.")
        #expect(result.calls == 2)
        #expect(await single.raw == "full raw fixture")
    }

    // Stalled by 200 ms: fake clock assertions still pass deterministically.
    @Test func failedMidStartsSingleImmediatelyManualClockUnderStallGreen() async throws {
        let manual = ManualClock()
        let transport = StallIncrementalTransport()
        let incremental = IncrementalCleaner(cleaner: cleaner(transport), raceAfterMs: 30, clock: manual)
        for index in 0..<2 { incremental.append(index: index, text: chunkText) }
        try await transport.wait(1)
        await transport.fail(0)
        await incremental.waitForPending()
        incremental.seal()
        incremental.append(index: 2, text: chunkText)
        let single = StallSingleProbe(delayMs: 0, stallMs: 200, clock: manual)
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

    // MARK: - (b) raceStartsSingleAfter600: 850 ms bound with 300 ms stall

    // Stalled by 300 ms on an 850 ms total bound: breaks the wall-clock bound deterministically.
    @Test func raceStartsSingleAfter600RealClockUnderStallRed() async throws {
        let transport = StallRaceTransport(midMs: 1_000)
        let incremental = IncrementalCleaner(cleaner: TranscriptCleaner(
            transport: transport, vocabulary: "", apiKey: { "hermetic-key" }))
        incremental.append(index: 0, text: chunkText)
        incremental.append(index: 1, text: chunkText)
        try await transport.waitForStart()
        incremental.seal()
        incremental.append(index: 2, text: chunkText)
        let single = StallSingleProbe(delayMs: 5, stallMs: 300)
        let start = ContinuousClock.now
        await transport.anchor(start)
        let result = await incremental.finish(totalChunks: 3, rawText: chunkText + " " + chunkText + " " + chunkText,
            single: { raw in await single.clean(raw) })
        #expect(result.mode == "race_single")
        #expect(result.text == "Single winner.")
        #expect(result.calls == 2)
        #expect(result.fallbackReason == "mid_slow_at_finish")
        withKnownIssue("real clock under a 300 ms stall breaks the wall-clock bound") {
            #expect(start.duration(to: .now) < .milliseconds(850))
        }
        let delay = try #require(await single.startedAt)
        #expect(start.duration(to: delay) >= .milliseconds(580))
        #expect(await single.raw == chunkText + " " + chunkText + " " + chunkText)
        try await transport.waitForCancellation()
    }

    // Stalled by 300 ms: fake clock assertions still pass deterministically.
    @Test func raceStartsSingleAfter600ManualClockUnderStallGreen() async throws {
        let manual = ManualClock()
        let transport = StallRaceTransport(midMs: 1_000, clock: manual)
        let incremental = IncrementalCleaner(cleaner: TranscriptCleaner(
            transport: transport, vocabulary: "", apiKey: { "hermetic-key" }), clock: manual)
        incremental.append(index: 0, text: chunkText)
        incremental.append(index: 1, text: chunkText)
        try await transport.waitForStart()
        incremental.seal()
        incremental.append(index: 2, text: chunkText)
        let single = StallSingleProbe(delayMs: 5, stallMs: 300, clock: manual)
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
        manual.advance(by: .milliseconds(10))
        let result = await finishTask.value
        #expect(result.mode == "race_single")
        #expect(result.text == "Single winner.")
        #expect(result.calls == 2)
        #expect(result.fallbackReason == "mid_slow_at_finish")
        #expect(manual.elapsed < .milliseconds(850))
        let delay = try #require(await single.startedAtElapsed)
        #expect(delay >= .milliseconds(600) && delay < .milliseconds(650))
        #expect(await single.raw == chunkText + " " + chunkText + " " + chunkText)
        try await transport.waitForCancellation()
    }

    // MARK: - (c) hedgeFiresOnSlowChunk: 1_000 ms bound with 1_050 ms stall

    // Stalled by 1_050 ms (>= 1_000 ms) on a 1_000 ms bound: breaks the wall-clock bound deterministically.
    @Test func hedgeFiresOnSlowChunkRealClockUnderStallRed() async throws {
        let transport = StallHedgeTransport(stallMs: 1_050)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" },
                                            prompt: "fixture", hedgeAfterMs: 50)
        engine.submit(chunk(0, tag: 1000))
        let start = ContinuousClock.now
        let result = await engine.finish()
        withKnownIssue("real clock under a 1000 ms stall breaks the wall-clock bound") {
            #expect(start.duration(to: .now) < .milliseconds(1_000))
        }
        #expect(result.text == "duplicate")
        #expect(result.hedges == 1)
        #expect(result.hedgeWins == 1)
        #expect(result.calls.first?.hedgeFired == true)
        #expect(result.calls.first?.winningRequest == 2)
        #expect(result.failedCount == 0)
        let requests = await transport.requests
        #expect(requests.count == 2)
        if requests.count == 2 { #expect(requests[0].httpBody == requests[1].httpBody) }
        try await transport.waitForCancellation(1)
    }

    // Stalled by 1_050 ms: fake clock assertions still pass deterministically.
    @Test func hedgeFiresOnSlowChunkManualClockUnderStallGreen() async throws {
        let manual = ManualClock()
        let transport = StallHedgeTransport(stallMs: 1_050, clock: manual)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" },
                                            prompt: "fixture", hedgeAfterMs: 50, clock: manual)
        engine.submit(chunk(0, tag: 1000))
        let finishTask = Task { await engine.finish() }
        #expect(await manual.waitForSleepers(2))
        manual.advance(by: .milliseconds(50))
        #expect(await manual.waitForSleepers(2))
        manual.advance(by: .milliseconds(1))
        let result = await finishTask.value
        #expect(manual.elapsed < .milliseconds(1_000))
        let requestTimes = await transport.requestTimes
        #expect(requestTimes.count >= 2 && requestTimes[1] == .milliseconds(50))
        #expect(result.text == "duplicate")
        #expect(result.hedges == 1)
        #expect(result.hedgeWins == 1)
        #expect(result.calls.first?.hedgeFired == true)
        #expect(result.calls.first?.winningRequest == 2)
        #expect(result.failedCount == 0)
        let requests = await transport.requests
        #expect(requests.count == 2)
        if requests.count == 2 { #expect(requests[0].httpBody == requests[1].httpBody) }
        try await transport.waitForCancellation(1)
    }
}
