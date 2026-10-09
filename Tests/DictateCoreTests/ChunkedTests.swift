import Foundation
import Testing
import DictateCore

/// Responses are released explicitly: concurrency tests need no network or timers.
private actor ChunkTransport: HTTPTransport {
    private struct Pending {
        let tag: Int
        let request: URLRequest
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    }
    private struct Waiter {
        let tag: Int
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }
    private var pending: [Pending] = []
    private var requests: [Int: [URLRequest]] = [:]
    private var waiters: [Waiter] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody!
        let riff = body.range(of: Data("RIFF".utf8))!.lowerBound
        let offset = riff + 44
        let tag = Int(Int16(bitPattern: UInt16(body[offset]) | UInt16(body[offset + 1]) << 8))
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(tag: tag, request: request, continuation: continuation))
            requests[tag, default: []].append(request)
            let ready = waiters.filter { requests[$0.tag, default: []].count >= $0.count }
            waiters.removeAll { requests[$0.tag, default: []].count >= $0.count }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func wait(tag: Int, count: Int = 1) async {
        if requests[tag, default: []].count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(tag: tag, count: count, continuation: continuation))
        }
    }

    func respond(tag: Int, status: Int = 200, text: String = "hello", headers: [String: String] = [:],
                 malformed: Bool = false, networkFailure: Bool = false) throws {
        let index = try #require(pending.firstIndex { $0.tag == tag })
        let item = pending.remove(at: index)
        if networkFailure {
            item.continuation.resume(throwing: URLError(.timedOut))
            return
        }
        let data = malformed ? Data("bad json".utf8) : try JSONSerialization.data(withJSONObject: ["text": text])
        let response = HTTPURLResponse(url: item.request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        item.continuation.resume(returning: (data, response))
    }

    func request(tag: Int, attempt: Int = 0) -> URLRequest { requests[tag]![attempt] }
    func count(tag: Int) -> Int { requests[tag, default: []].count }
}

/// Timed, cancellation-aware responses exercise the hedge without networking.
private actor HedgeTransport: HTTPTransport {
    enum Plan { case duplicateWins, primaryWins, fast, failures, duplicateFails, primaryFails }
    let plan: Plan
    private(set) var requests: [URLRequest] = []
    private(set) var cancelled: Set<Int> = []
    init(_ plan: Plan) { self.plan = plan }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let number = requests.count + 1
        requests.append(request)
        let delay: Int
        switch plan {
        case .fast: delay = 10
        case .duplicateWins: delay = number == 1 ? 250 : 1
        case .primaryWins: delay = number == 1 ? 80 : 250
        case .failures: delay = number == 1 ? 80 : 60
        case .duplicateFails: delay = number == 1 ? 100 : 1
        case .primaryFails: delay = number == 1 ? 70 : 40
        }
        do { try await Task.sleep(for: .milliseconds(delay)) }
        catch { cancelled.insert(number); throw error }
        let fails = plan == .failures || (plan == .duplicateFails && number == 2) ||
                    (plan == .primaryFails && number == 1)
        if fails { throw URLError(.timedOut) }
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

@Suite("PauseChunker")
struct PauseChunkerTests {
    private func pcm(_ seconds: Double, _ value: Int16 = 12_000) -> [Int16] {
        [Int16](repeating: value, count: Int((seconds * 24_000).rounded()))
    }

    @Test func finalSplitLeavesShortTail() throws {
        var chunker = PauseChunker(firstMinimumSeconds: 7, firstMaximumSeconds: 8)
        let input = pcm(4.2) + pcm(0.1, 400) + pcm(1.7)
        #expect(chunker.append(input).isEmpty)
        let pieces = chunker.finish(splitOver: 2)
        #expect(pieces.map(\.samples.count) == [100_800, 43_200])
        #expect(pieces.map(\.index) == [0, 1])
        #expect(pieces.flatMap(\.samples) == input)
        #expect(chunker.finish(splitOver: 2).isEmpty)
    }

    @Test func noSplitUnderTwoSeconds() {
        var chunker = PauseChunker()
        _ = chunker.append(pcm(2))
        #expect(chunker.finish(splitOver: 2).map(\.samples.count) == [48_000])
    }

    @Test func splitThresholdStillCapsTailAtTwoSeconds() {
        var chunker = PauseChunker(firstMinimumSeconds: 7, firstMaximumSeconds: 8)
        let input = pcm(3.2) + pcm(0.1, 400) + pcm(2.7)
        _ = chunker.append(input)
        let pieces = chunker.finish(splitOver: 3)
        #expect(pieces.count == 2)
        #expect(pieces.last.map { (12_000...48_000).contains($0.samples.count) } == true)
        #expect(pieces.flatMap(\.samples) == input)
    }

    @Test func splitDisabledByNil() {
        var chunker = PauseChunker(firstMinimumSeconds: 7, firstMaximumSeconds: 8)
        _ = chunker.append(pcm(6))
        #expect(chunker.finish(splitOver: nil).map(\.samples.count) == [144_000])
    }

    @Test func finalSplitTrimsFirstAndBoundsTail() {
        var chunker = PauseChunker(firstMinimumSeconds: 7, firstMaximumSeconds: 8)
        _ = chunker.append(pcm(4.2) + pcm(0.1, 400) + pcm(0.7) + pcm(1, 0))
        let pieces = chunker.finish(splitOver: 2)
        #expect(pieces.map(\.samples.count) == [100_800, 25_200])
        #expect(pieces.last.map { (12_000...48_000).contains($0.samples.count) } == true)
    }

    @Test func firstChunkCutsAfterThreeSecondsAnd150MillisecondsOfQuiet() {
        var chunker = PauseChunker()
        #expect(chunker.append(pcm(0.1, 0)).isEmpty)
        #expect(chunker.append(pcm(2.9)).isEmpty)
        #expect(chunker.append(pcm(0.1, 0)).isEmpty)
        let chunks = chunker.append(pcm(0.05, 0))
        #expect(chunks.count == 1)
        #expect(chunks.first?.samples.count == 72_000)
        #expect(chunks.first?.index == 0)
    }

    @Test func quietBeforeMinimumWaitsForThreeSecondsPlus150Milliseconds() {
        var chunker = PauseChunker()
        _ = chunker.append(pcm(0.1, 0))
        _ = chunker.append(pcm(2.8))
        #expect(chunker.append(pcm(0.2, 0)).isEmpty)
        let chunks = chunker.append(pcm(0.05, 0))
        #expect(chunks.first?.samples.count == 72_000)
    }

    @Test func laterChunksRequireFourSecondsAnd250MillisecondsOfQuiet() {
        var chunker = PauseChunker()
        _ = chunker.append(pcm(0.1, 0))
        _ = chunker.append(pcm(2.9))
        let first = chunker.append(pcm(0.15, 0))
        #expect(first.first?.index == 0)
        #expect(chunker.append(pcm(3.85)).isEmpty) // Retained quiet + speech = 4 s.
        #expect(chunker.append(pcm(0.2, 0)).isEmpty)
        let later = chunker.append(pcm(0.05, 0))
        #expect(later.count == 1)
        #expect(later.first?.index == 1)
        #expect(later.first?.samples.count == 96_000)
    }

    @Test func firstForcedCutAtFourSecondsUsesQuietest100MillisecondsInLastSecond() {
        var chunker = PauseChunker()
        _ = chunker.append(pcm(0.1, 0))
        _ = chunker.append(pcm(3.3))
        #expect(chunker.append(pcm(0.1, 400)).isEmpty) // Below the 150 ms pause threshold.
        #expect(chunker.append(pcm(0.45)).isEmpty)
        let chunks = chunker.append(pcm(0.05))
        #expect(chunks.count == 1)
        #expect(chunks.first?.samples.count == 81_600) // 3.4 s; opening silence excluded.
        #expect(chunker.finish().first?.samples.count == 14_400)
    }

    @Test func laterForcedCutAtSixSecondsUsesQuietest100Milliseconds() {
        var chunker = PauseChunker()
        _ = chunker.append(pcm(0.1, 0))
        _ = chunker.append(pcm(2.9))
        _ = chunker.append(pcm(0.15, 0))
        _ = chunker.append(pcm(5.05)) // Including retained quiet: 5.2 s.
        #expect(chunker.append(pcm(0.1, 400)).isEmpty)
        #expect(chunker.append(pcm(0.65)).isEmpty)
        let chunks = chunker.append(pcm(0.05))
        #expect(chunks.count == 1)
        #expect(chunks.first?.index == 1)
        #expect(chunks.first?.samples.count == 124_800) // 5.2 s.
        #expect(chunker.finish().first?.samples.count == 19_200)
    }

    @Test func forcedCutMeasuresWhole100MillisecondWindow() {
        var chunker = PauseChunker()
        _ = chunker.append(pcm(0.1, 0))
        _ = chunker.append(pcm(3.1))
        _ = chunker.append(pcm(0.05, 100)) // One quiet 50 ms slice beside loud speech.
        _ = chunker.append(pcm(0.05))
        _ = chunker.append(pcm(0.1, 800)) // Quieter across the whole 100 ms.
        let chunks = chunker.append(pcm(0.6))
        #expect(chunks.first?.samples.count == 79_200) // 3.3 s.
    }

    @Test func largeInputCutsFirstAtFourThenLaterAtSixSeconds() {
        var chunker = PauseChunker()
        _ = chunker.append(pcm(0.1, 0))
        let chunks = chunker.append(pcm(15.9))
        #expect(chunks.count == 3)
        #expect(chunks.map(\.samples.count) == [93_600, 141_600, 141_600])
        #expect(chunks.map(\.index) == [0, 1, 2])
    }

    @Test func arbitraryBufferSizesPreserveEverySampleAndIndices() {
        let input = (0..<560_123).map { Int16(($0 % 20_000) - 10_000) }
        var chunker = PauseChunker()
        var chunks: [PauseChunker.Chunk] = []
        for offset in stride(from: 0, to: input.count, by: 3_713) {
            chunks += chunker.append(Array(input[offset..<min(input.count, offset + 3_713)]))
        }
        #expect(chunks.first.map { (72_000...96_000).contains($0.samples.count) } == true)
        #expect(chunks.dropFirst().allSatisfy { (96_000...144_000).contains($0.samples.count) })
        chunks += chunker.finish()
        #expect(chunks.flatMap(\.samples) == input)
        #expect(chunks.map(\.index) == Array(chunks.indices))
        #expect(chunker.finish().isEmpty)
        #expect(chunker.append([1, 2, 3]).isEmpty)
    }

    @Test func finalPartialCanBeShorterThanMinimumCut() {
        var chunker = PauseChunker()
        #expect(chunker.append(pcm(0.3)).isEmpty)
        #expect(chunker.finish() == [.init(index: 0, samples: pcm(0.3))])
        var empty = PauseChunker()
        #expect(empty.finish().isEmpty)
    }

    @Test func finishTrimsTrailingSilence() throws {
        var chunker = PauseChunker()
        #expect(chunker.append(pcm(1.5) + pcm(1.0, 0)).isEmpty)
        let chunks = chunker.finish()
        #expect(chunks.count == 1)
        let chunk = try #require(chunks.first)
        #expect(chunk.samples.count >= 36_000)
        #expect(chunk.samples.count <= 42_000)
        #expect(Array(chunk.samples.prefix(36_000)) == pcm(1.5))
        #expect(chunker.finish().isEmpty)
    }

    @Test func finishDropsAllQuietPartial() {
        var chunker = PauseChunker()
        _ = chunker.append(pcm(0.1, 0))
        _ = chunker.append(pcm(2.9))
        let cuts = chunker.append(pcm(0.15, 0))
        #expect(cuts.count == 1)
        #expect(chunker.append(pcm(0.8, 0)).isEmpty)
        #expect(chunker.finish().isEmpty)
        #expect(chunker.finish().isEmpty)
    }

    @Test(arguments: [1, 599, 1_199]) func finishTrimsIncompleteQuietWindow(extraSamples: Int) throws {
        var chunker = PauseChunker()
        let speech = pcm(1.5)
        #expect(chunker.append(speech + pcm(1.0, 0) + Array(repeating: 0, count: extraSamples)).isEmpty)
        let chunk = try #require(chunker.finish().first)
        #expect(chunk.samples.count == speech.count + 6_000)
        #expect(Array(chunk.samples.prefix(speech.count)) == speech)
    }

    @Test func finishDropsQuietPartialWithoutCompleteWindow() {
        var chunker = PauseChunker()
        #expect(chunker.append(Array(repeating: 0, count: 599)).isEmpty)
        #expect(chunker.finish().isEmpty)
    }

    @Test func firstChunkWaitsThreeSeconds() {
        var chunker = PauseChunker()
        #expect(chunker.append(pcm(0.1, 0)).isEmpty)
        #expect(chunker.append(pcm(2.1)).isEmpty)
        #expect(chunker.append(pcm(0.15, 0)).isEmpty) // Pause at 2.2 s must not cut.
        #expect(chunker.append(pcm(0.75)).isEmpty)
        let chunks = chunker.append(pcm(0.15, 0)) // Pause at 3.1 s does cut.
        #expect(chunks.count == 1)
        #expect(chunks.first?.index == 0)
        #expect(chunks.first.map { $0.samples.count >= 72_000 } == true)
    }

    @Test func firstChunkHardCutAtFour() {
        var chunker = PauseChunker()
        #expect(chunker.append(pcm(0.1, 0)).isEmpty) // Establish the noise floor before speech.
        #expect(chunker.append(pcm(3.85)).isEmpty)
        let chunks = chunker.append(pcm(0.05))
        #expect(chunks.count == 1)
        #expect(chunks.first?.index == 0)
        #expect(chunks.first.map { (72_000...96_000).contains($0.samples.count) } == true)
    }

    @Test func oldVariantStillTwoThree() {
        var paused = PauseChunker(firstMinimumSeconds: 2, firstMaximumSeconds: 3)
        #expect(paused.append(pcm(0.1, 0)).isEmpty)
        #expect(paused.append(pcm(1.9)).isEmpty)
        #expect(paused.append(pcm(0.1, 0)).isEmpty)
        let pauseCut = paused.append(pcm(0.05, 0))
        #expect(pauseCut.count == 1)
        #expect(pauseCut.first?.samples.count == 48_000)

        var continuous = PauseChunker(firstMinimumSeconds: 2, firstMaximumSeconds: 3)
        #expect(continuous.append(pcm(0.1, 0)).isEmpty)
        #expect(continuous.append(pcm(2.85)).isEmpty)
        let hardCut = continuous.append(pcm(0.05))
        #expect(hardCut.count == 1)
        #expect(hardCut.first?.samples.count == 69_600)
    }

}

@Suite("GroqChunkedTranscriber")
struct GroqChunkedTests {
    private func engine(_ transport: ChunkTransport, prompt: String = "Kubernetes, PostgreSQL",
                        fillerLeadIn: Bool = true) -> GroqChunkedTranscriber {
        GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" }, prompt: prompt,
                               fillerLeadIn: fillerLeadIn)
    }
    private func chunk(_ index: Int, tag: Int16) -> PauseChunker.Chunk {
        .init(index: index, samples: [Int16](repeating: tag, count: 2_400))
    }

    @Test func hedgeFiresOnSlowChunkAndFirstWins() async throws {
        let transport = HedgeTransport(.duplicateWins)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" },
                                            prompt: "fixture", hedgeAfterMs: 50)
        engine.submit(chunk(0, tag: 1000))
        let start = ContinuousClock.now
        let result = await engine.finish()
        #expect(start.duration(to: .now) < .milliseconds(200))
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

    @Test func noHedgeWhenFast() async {
        let transport = HedgeTransport(.fast)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" },
                                            prompt: "", hedgeAfterMs: 50)
        engine.submit(chunk(0, tag: 1000))
        let result = await engine.finish()
        #expect(result.text == "primary")
        #expect(result.hedges == 0)
        #expect(result.hedgeWins == 0)
        #expect(result.calls.first?.hedgeFired == false)
        #expect(result.calls.first?.winningRequest == 1)
        #expect(await transport.requests.count == 1)
    }

    @Test func hedgeCapsRequests() async {
        let transport = HedgeTransport(.failures)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" },
                                            prompt: "", hedgeAfterMs: 50)
        engine.submit(chunk(0, tag: 1000))
        let result = await engine.finish()
        #expect(await transport.requests.count == 3) // Positive control: hedge + unhedged retry.
        #expect(result.hedges == 1)
        #expect(result.hedgeWins == 0)
        #expect(result.failedCount == 1)
        #expect(result.text.isEmpty)
        #expect(result.calls.map(\.attempt) == [1, 2])
        #expect(result.calls.map(\.hedgeFired) == [true, false])
        #expect(result.calls.allSatisfy { $0.winningRequest == nil })
    }

    @Test func primaryCanWinAfterHedge() async throws {
        let transport = HedgeTransport(.primaryWins)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" },
                                            prompt: "", hedgeAfterMs: 50)
        engine.submit(chunk(0, tag: 1000))
        let result = await engine.finish()
        #expect(result.text == "primary")
        #expect(result.hedges == 1)
        #expect(result.hedgeWins == 0)
        #expect(result.calls.first?.winningRequest == 1)
        try await transport.waitForCancellation(2)
    }

    @Test(arguments: [false, true])
    func hedgeWaitsForFirstSuccess(primaryFails: Bool) async {
        let transport = HedgeTransport(primaryFails ? .primaryFails : .duplicateFails)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" },
                                            prompt: "", hedgeAfterMs: 50)
        engine.submit(chunk(0, tag: 1000))
        let result = await engine.finish()
        #expect(result.text == (primaryFails ? "duplicate" : "primary"))
        #expect(result.hedges == 1)
        #expect(result.hedgeWins == (primaryFails ? 1 : 0))
        #expect(result.failedCount == 0)
        #expect(await transport.requests.count == 2)
    }

    @Test func transcriberFinalSplitUploadsBothConcurrently() async throws {
        let transport = ChunkTransport()
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" }, prompt: "",
            firstMinimumSeconds: 7, firstMaximumSeconds: 8)
        let pcm = [Int16](repeating: 1000, count: 100_800) +
            [Int16](repeating: 400, count: 2_400) + [Int16](repeating: 2000, count: 40_800)
        engine.append(pcm)
        let finish = Task { await engine.finish() }
        await transport.wait(tag: 1000)
        await transport.wait(tag: 400) // Both start before either response.
        try await transport.respond(tag: 400, text: "Tail")
        try await transport.respond(tag: 1000, text: "Prefix")
        let result = await finish.value
        #expect(result.chunks == 2)
        #expect(result.text == "Prefix Tail")
        #expect(result.failedCount == 0)
        #expect(result.hedges == 0)
    }

    @Test func finalSplitUploadsEvenAShortPrefix() async {
        let transport = HedgeTransport(.fast)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" }, prompt: "")
        engine.append([Int16](repeating: 1000, count: 1_200) +
                      [Int16](repeating: 400, count: 2_400) + [Int16](repeating: 2000, count: 45_600))
        let result = await engine.finish()
        #expect(result.chunks == 2)
        #expect(await transport.requests.count == 2)
        #expect(result.failedCount == 0)
    }

    @Test func transcriberFinalSplitDisabledByNil() async throws {
        let transport = ChunkTransport()
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" }, prompt: "",
            firstMinimumSeconds: 7, firstMaximumSeconds: 8, finalSplitSeconds: nil)
        engine.append([Int16](repeating: 1000, count: 144_000))
        let finish = Task { await engine.finish() }
        await transport.wait(tag: 1000)
        try await transport.respond(tag: 1000)
        let result = await finish.value
        #expect(result.chunks == 1)
        #expect(result.failedCount == 0)
    }

    @Test func joinsOutOfOrderAndDoesNotWaitForPreviousTail() async throws {
        let transport = ChunkTransport()
        let engine = engine(transport)
        engine.submit(chunk(0, tag: 1000))
        await transport.wait(tag: 1000)
        let second = engine.submit(chunk(1, tag: 2000))
        await transport.wait(tag: 2000) // Both in flight; no previous response.
        let request = await transport.request(tag: 2000)
        #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("name=\"prompt\"\r\n\r\nUm, so, uh, like, Kubernetes, PostgreSQL\r\n"))
        try await transport.respond(tag: 2000, text: " second \n", headers: ["x-ratelimit-remaining-requests": "98"])
        await second?.value
        try await transport.respond(tag: 1000, text: " first ", headers: ["x-ratelimit-remaining-requests": "97"])
        let result = await engine.finish()
        #expect(result.text == "first second")
        #expect(result.chunks == 2)
        #expect(result.failedCount == 0)
        #expect(result.calls.count == 2)
        #expect(result.calls.allSatisfy { $0.milliseconds >= 0 && $0.attempt == 1 })
        #expect(result.rateLimits?.rpdRemaining == "97") // Last response, not highest index.
    }

    @Test func usesAvailablePreviousTailAtSendTimeCappedAt200Characters() async throws {
        let transport = ChunkTransport()
        let engine = engine(transport)
        let first = engine.submit(chunk(0, tag: 1000))
        await transport.wait(tag: 1000)
        let previous = "discarded prefix " + String(repeating: "é", count: 200)
        try await transport.respond(tag: 1000, text: previous)
        await first?.value
        engine.submit(chunk(1, tag: 2000))
        await transport.wait(tag: 2000)
        let body = String(decoding: await transport.request(tag: 2000).httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"prompt\"\r\n\r\nUm, so, uh, like, Kubernetes, PostgreSQL " + String(repeating: "é", count: 200) + "\r\n"))
        #expect(!body.contains("discarded prefix"))
        try await transport.respond(tag: 2000, text: "next")
        #expect(await engine.finish().text == previous + " next")
    }

    @Test func retriesExactlyOnceAndReportsFailure() async throws {
        let transport = ChunkTransport()
        let engine = engine(transport)
        engine.submit(chunk(0, tag: 1000))
        await transport.wait(tag: 1000)
        try await transport.respond(tag: 1000, status: 503)
        await transport.wait(tag: 1000, count: 2)
        try await transport.respond(tag: 1000, status: 429, headers: ["retry-after": "2"])
        let result = await engine.finish()
        #expect(result.failedCount == 1)
        #expect(result.text.isEmpty)
        #expect(await transport.count(tag: 1000) == 2)
        #expect(result.calls.map(\.attempt) == [1, 2])
        #expect(result.rateLimits?.headers["retry-after"] == "2")
    }

    @Test func retryRecoversNetworkFailure() async throws {
        let transport = ChunkTransport()
        let engine = engine(transport)
        engine.submit(chunk(0, tag: 1000))
        await transport.wait(tag: 1000)
        try await transport.respond(tag: 1000, networkFailure: true)
        await transport.wait(tag: 1000, count: 2)
        try await transport.respond(tag: 1000, text: "recovered")
        let result = await engine.finish()
        #expect(result.failedCount == 0)
        #expect(result.text == "recovered")
        #expect(result.calls.count == 2)
    }

    @Test func malformedJSONRetriesAndOtherChunksRemainAvailable() async throws {
        let transport = ChunkTransport()
        let engine = engine(transport)
        engine.submit(chunk(0, tag: 1000))
        engine.submit(chunk(1, tag: 2000))
        await transport.wait(tag: 1000)
        await transport.wait(tag: 2000)
        try await transport.respond(tag: 1000, malformed: true)
        await transport.wait(tag: 1000, count: 2)
        try await transport.respond(tag: 1000, malformed: true)
        try await transport.respond(tag: 2000, text: "successful chunk")
        let result = await engine.finish()
        #expect(result.failedCount == 1)
        #expect(result.chunks == 2)
        #expect(result.text == "successful chunk")
    }

    @Test func finishUploadsAtLeast300MillisecondsAndDropsShorterTail() async throws {
        let transport = ChunkTransport()
        let short = engine(transport)
        short.append([Int16](repeating: 1000, count: 7_199)) // RED: below 300 ms.
        #expect(await short.finish().chunks == 0)
        let engine = engine(transport)
        engine.append([Int16](repeating: 2000, count: 7_200)) // GREEN: exactly 300 ms.
        let finish = Task { await engine.finish() }
        await transport.wait(tag: 2000)
        try await transport.respond(tag: 2000, text: "partial")
        let result = await finish.value
        #expect(result.chunks == 1)
        #expect(result.text == "partial")
        #expect(await engine.finish().chunks == 1) // Idempotent; never reuploads.
        engine.append([Int16](repeating: 2000, count: 7_200))
        #expect(await engine.finish().chunks == 1)
    }

    @Test func multipartAndResampledWAVAreCompleteEvenWithEmptyPrompt() async throws {
        let transport = ChunkTransport()
        let engine = engine(transport, prompt: "")
        engine.submit(chunk(0, tag: 1000))
        await transport.wait(tag: 1000)
        let request = await transport.request(tag: 1000)
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        for part in ["name=\"model\"\r\n\r\nwhisper-large-v3-turbo", "name=\"response_format\"\r\n\r\njson",
                     "name=\"language\"\r\n\r\nen", "name=\"prompt\"\r\n\r\nUm, so, uh, like, \r\n",
                     "name=\"file\"; filename=\"audio.wav\"", "Content-Type: audio/wav"] {
            #expect(text.contains(part))
        }
        let riff = try #require(body.range(of: Data("RIFF".utf8)))
        let wav = body.subdata(in: riff.lowerBound..<(riff.lowerBound + 44 + 3_200))
        #expect(wav == WAVEncoder.encode(samples: [Int16](repeating: 1000, count: 1_600), sampleRate: 16_000))
        #expect(request.url == TranscriptionClient.groqEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hermetic-key")
        try await transport.respond(tag: 1000)
        #expect(await engine.finish().failedCount == 0)
    }

    @Test func promptHasFillerLeadIn() async throws {
        let transport = ChunkTransport()
        let engine = engine(transport)
        engine.submit(chunk(0, tag: 1000))
        await transport.wait(tag: 1000)
        let body = String(decoding: await transport.request(tag: 1000).httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"prompt\"\r\n\r\nUm, so, uh, like, Kubernetes, PostgreSQL\r\n"))
        try await transport.respond(tag: 1000)
        #expect(await engine.finish().failedCount == 0)

        let old = self.engine(transport, fillerLeadIn: false)
        old.submit(chunk(0, tag: 2000))
        await transport.wait(tag: 2000)
        let oldBody = String(decoding: await transport.request(tag: 2000).httpBody!, as: UTF8.self)
        #expect(oldBody.contains("name=\"prompt\"\r\n\r\nKubernetes, PostgreSQL\r\n"))
        #expect(!oldBody.contains("Um, so, uh, like,"))
        #expect(GroqChunkedTranscriber.fillerLeadIn == "Um, so, uh, like,")
        try await transport.respond(tag: 2000)
        #expect(await old.finish().failedCount == 0)
    }

    @Test func vocabularyCapPreservesLeadInAndPreviousTail() async throws {
        let transport = ChunkTransport()
        let vocab = String(repeating: "é", count: 800)
        let engine = engine(transport, prompt: vocab + "discarded vocabulary")
        let first = engine.submit(chunk(0, tag: 1000))
        await transport.wait(tag: 1000)
        let firstBody = String(decoding: await transport.request(tag: 1000).httpBody!, as: UTF8.self)
        #expect(firstBody.contains("name=\"prompt\"\r\n\r\nUm, so, uh, like, " + vocab + "\r\n"))
        #expect(!firstBody.contains("discarded vocabulary"))
        let tail = String(repeating: "t", count: 200)
        try await transport.respond(tag: 1000, text: "discarded tail " + tail)
        await first?.value
        engine.submit(chunk(1, tag: 2000))
        await transport.wait(tag: 2000)
        let nextBody = String(decoding: await transport.request(tag: 2000).httpBody!, as: UTF8.self)
        #expect(nextBody.contains("name=\"prompt\"\r\n\r\nUm, so, uh, like, " + vocab + " " + tail + "\r\n"))
        #expect(!nextBody.contains("discarded tail"))
        try await transport.respond(tag: 2000)
        #expect(await engine.finish().failedCount == 0)
    }

    @Test func internalChunkerPassesThroughFirstLimits() async throws {
        for (minimum, maximum) in [(3.0, 4.0), (2.0, 3.0)] {
            let transport = ChunkTransport()
            let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "hermetic-key" }, prompt: "",
                                               firstMinimumSeconds: minimum, firstMaximumSeconds: maximum)
            engine.append([Int16](repeating: 0, count: 2_400))
            engine.append([Int16](repeating: 1000, count: Int(minimum * 24_000) - 2_400))
            engine.append([Int16](repeating: 0, count: 3_600))
            await transport.wait(tag: 0) // The first sample is retained opening silence.
            let body = await transport.request(tag: 0).httpBody!
            let riff = try #require(body.range(of: Data("RIFF".utf8)))
            let bytes = Int(minimum * 16_000) * 2
            let wavHeader = Array(body[riff.lowerBound..<(riff.lowerBound + 44)])
            let dataSize = Int(wavHeader[40]) | Int(wavHeader[41]) << 8 |
                           Int(wavHeader[42]) << 16 | Int(wavHeader[43]) << 24
            #expect(dataSize == bytes)
            try await transport.respond(tag: 0)
            #expect(await engine.finish().chunks == 1) // The retained 150 ms tail is dropped.
        }
    }

    @Test func parsesAllRateLimitHeadersAndAbsence() {
        let headers = ["X-Ratelimit-Limit-Requests": "1000", "X-Ratelimit-Remaining-Requests": "999",
                       "X-Ratelimit-Limit-Tokens": "6000", "X-Ratelimit-Remaining-Tokens": "5999", "Retry-After": "2"]
        let response = HTTPURLResponse(url: TranscriptionClient.groqEndpoint, statusCode: 429,
                                       httpVersion: nil, headerFields: headers)!
        let limits = GroqChunkedTranscriber.RateLimits(response: response)
        #expect(limits.headers.count == 5)
        #expect(limits.headers["x-ratelimit-limit-requests"] == "1000")
        #expect(limits.rpdRemaining == "999")
        #expect(limits.rpmRemaining == "-") // No RPM header; tokens are not requests.
        #expect(limits.headers["x-ratelimit-limit-tokens"] == "6000")
        #expect(limits.headers["x-ratelimit-remaining-tokens"] == "5999")
        #expect(limits.headers["retry-after"] == "2")
        let empty = GroqChunkedTranscriber.RateLimits(response: HTTPURLResponse(
            url: TranscriptionClient.groqEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        #expect(empty.headers.isEmpty)
        #expect(empty.rpdRemaining == "-")
    }

    @Test func resamplingRejectsOutOfBandAudioAndPreservesDC() {
        #expect(GroqChunkedTranscriber.resampleTo16k([]).isEmpty)
        #expect(GroqChunkedTranscriber.resampleTo16k([Int16](repeating: 1200, count: 2400)) == [Int16](repeating: 1200, count: 1600))
        let high = (0..<2400).map { Int16((12_000 * sin(2 * .pi * 10_000 * Double($0) / 24_000)).rounded()) }
        let filtered = GroqChunkedTranscriber.resampleTo16k(high)
        let rms = sqrt(filtered[20..<1580].reduce(0.0) { $0 + Double($1) * Double($1) } / 1560)
        #expect(rms < 200)
    }

    @Test func chunkLogFieldsContainCountsOnly() {
        var entry = DictationLogEntry(time: Date(timeIntervalSince1970: 0), durationSeconds: 10, audioBytes: 100,
                                     latencyMs: 123, chars: 25, frontmostBundleID: "test", outcome: .ok)
        entry.path = "groq-chunked"
        entry.chunks = 3
        entry.lastChunkMs = 100
        entry.sttMs = 101
        #expect(entry.formatted().contains("path=groq-chunked stt_ms=101 chunks=3 last_chunk_ms=100"))
        entry.path = "apple"
        entry.chunkFallback = 1
        #expect(entry.formatted().contains("path=apple"))
        #expect(entry.formatted().contains("chunk_fallback=1"))
        #expect(!entry.formatted().contains("text="))
    }
}
