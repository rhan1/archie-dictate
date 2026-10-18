import Foundation
import Testing
import DictateCore

/// Deterministic fake transport for Groq -> Scribe chunked fallback tests.
/// Never touches the network, keychain, or real timers.
private actor ScribeFakeTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var body: Data
        var delayMs: Int = 0
        var error: Error? = nil

        static func json(_ text: String, status: Int = 200, delayMs: Int = 0) -> Reply {
            let data = try! JSONSerialization.data(withJSONObject: ["text": text])
            return Reply(status: status, body: data, delayMs: delayMs)
        }

        static func raw(_ string: String, status: Int = 200, delayMs: Int = 0) -> Reply {
            Reply(status: status, body: Data(string.utf8), delayMs: delayMs)
        }

        static func status(_ code: Int, delayMs: Int = 0) -> Reply {
            Reply(status: code, body: Data(#"{"error":"failed"}"#.utf8), delayMs: delayMs)
        }

        static func failure(_ error: Error, delayMs: Int = 0) -> Reply {
            Reply(status: 500, body: Data(), delayMs: delayMs, error: error)
        }
    }

    struct RecordedRequest: Sendable {
        let request: URLRequest
        let tag: Int?
        let wavData: Data?
        let isScribe: Bool
        let order: Int
    }

    private var groqRepliesByTag: [Int: [Reply]] = [:]
    private var scribeRepliesByTag: [Int: [Reply]] = [:]
    private var defaultGroqReply: Reply = .status(403)
    private var defaultScribeReply: Reply = .json("scribe default")
    private(set) var recorded: [RecordedRequest] = []
    private(set) var completionOrder: [(isScribe: Bool, tag: Int?)] = []
    private var nextOrder = 0

    init(
        groqByTag: [Int: [Reply]] = [:],
        scribeByTag: [Int: [Reply]] = [:],
        defaultGroq: Reply = .status(403),
        defaultScribe: Reply = .json("scribe default")
    ) {
        self.groqRepliesByTag = groqByTag
        self.scribeRepliesByTag = scribeByTag
        self.defaultGroqReply = defaultGroq
        self.defaultScribeReply = defaultScribe
    }

    nonisolated static func extractWAV(from body: Data?) -> (tag: Int, wav: Data)? {
        guard let body,
              let riff = body.range(of: Data("RIFF".utf8)),
              body.count >= riff.lowerBound + 46 else { return nil }
        let start = riff.lowerBound
        let lengthOffset = start + 40
        let dataSize = Int(body[lengthOffset])
            | (Int(body[lengthOffset + 1]) << 8)
            | (Int(body[lengthOffset + 2]) << 16)
            | (Int(body[lengthOffset + 3]) << 24)
        let totalWAV = 44 + dataSize
        guard body.count >= start + totalWAV else { return nil }
        let sampleOffset = start + 44
        let tag = Int(Int16(bitPattern: UInt16(body[sampleOffset]) | (UInt16(body[sampleOffset + 1]) << 8)))
        let wav = body.subdata(in: start..<(start + totalWAV))
        return (tag, wav)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let extracted = Self.extractWAV(from: request.httpBody)
        let tag = extracted?.tag
        let isScribe = request.url == ScribeClient.endpoint
        nextOrder += 1
        recorded.append(RecordedRequest(
            request: request,
            tag: tag,
            wavData: extracted?.wav,
            isScribe: isScribe,
            order: nextOrder
        ))

        let reply: Reply
        if isScribe {
            if let tag, var queue = scribeRepliesByTag[tag], !queue.isEmpty {
                reply = queue.removeFirst()
                scribeRepliesByTag[tag] = queue
            } else {
                reply = defaultScribeReply
            }
        } else {
            if let tag, var queue = groqRepliesByTag[tag], !queue.isEmpty {
                reply = queue.removeFirst()
                groqRepliesByTag[tag] = queue
            } else {
                reply = defaultGroqReply
            }
        }

        if reply.delayMs > 0 {
            try await Task.sleep(for: .milliseconds(reply.delayMs))
        }
        if let error = reply.error {
            throw error
        }
        completionOrder.append((isScribe: isScribe, tag: tag))
        let response = HTTPURLResponse(
            url: request.url ?? ScribeClient.endpoint,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (reply.body, response)
    }

    var groqRequests: [RecordedRequest] { recorded.filter { !$0.isScribe } }
    var scribeRequests: [RecordedRequest] { recorded.filter { $0.isScribe } }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
    var count: Int { lock.withLock { value } }
}

private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, String)] = []
    func record(_ index: Int, _ text: String) {
        lock.withLock { items.append((index, text)) }
    }
    var events: [(Int, String)] { lock.withLock { items } }
}

@Suite("ScribeChunkedTests")
struct ScribeChunkedTests {
    private func speechChunk(_ index: Int, tag: Int16, sampleCount: Int = 2_400,
                             cutKind: PauseChunker.CutKind = .pause, quietRunMs: Int? = 250) -> PauseChunker.Chunk {
        .init(index: index, samples: [Int16](repeating: tag, count: sampleCount), cutKind: cutKind, quietRunMs: quietRunMs)
    }

    @Test func scribeClientMakeRequestAndTranscribeVerifyHeadersFieldsTimeoutAndDecode() async throws {
        let wav = WAVEncoder.encode(samples: [Int16](repeating: 1_234, count: 1_600), sampleRate: 16_000)
        let transport = ScribeFakeTransport(
            scribeByTag: [1234: [.json("  direct scribe transcript \n")]]
        )
        let client = ScribeClient(transport: transport, apiKey: { "  xi-secret-key \n" })
        let request = client.makeRequest(wav: wav, apiKey: "xi-secret-key", boundary: "scribe-boundary")

        #expect(request.url == URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-secret-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=scribe-boundary")

        let body = try #require(request.httpBody)
        let bodyString = String(decoding: body, as: UTF8.self)
        #expect(bodyString.contains("name=\"model_id\"\r\n\r\nscribe_v1\r\n"))
        #expect(bodyString.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(!bodyString.contains("name=\"prompt\""))
        #expect(!bodyString.contains("name=\"response_format\""))
        #expect(!bodyString.contains("name=\"model\""))
        #expect(body.range(of: wav) != nil)

        let text = try await client.transcribe(wav: wav)
        #expect(text == "direct scribe transcript")
        let sent = await transport.scribeRequests
        #expect(sent.count == 1)
        #expect(sent.first?.request.value(forHTTPHeaderField: "xi-api-key") == "xi-secret-key")
        #expect(sent.first?.request.timeoutInterval == 30)
    }

    @Test func groq403FallsBackToScribeAndPopulatesResultAndRequestContract() async throws {
        let transport = ScribeFakeTransport(
            groqByTag: [1000: [.status(403), .status(403)]],
            scribeByTag: [1000: [.json("recovered from elevenlabs scribe")]]
        )
        let engine = GroqChunkedTranscriber(
            transport: transport,
            apiKey: { "groq-key" },
            prompt: "Kubernetes, PostgreSQL",
            fillerLeadIn: false,
            hedgeAfterMs: 60_000,
            edgeGuard: false,
            scribeAPIKey: { "scribe-api-key-123" }
        )
        engine.submit(speechChunk(0, tag: 1000))
        let result = await engine.finish()

        #expect(result.text == "recovered from elevenlabs scribe")
        #expect(result.scribeChunks == 1)
        #expect(result.scribeNoKey == false)
        #expect(result.failedCount == 0)
        #expect(result.chunks == 1)

        // Preserve Groq attempt telemetry and record distinct Scribe call with model=scribe_v1.
        #expect(result.calls.count == 3)
        let groqCalls = result.calls.filter { $0.model == "whisper-large-v3-turbo" }
        let scribeCalls = result.calls.filter { $0.model == "scribe_v1" }
        #expect(groqCalls.map(\.attempt) == [1, 2])
        #expect(groqCalls.allSatisfy { $0.status == 403 && $0.winningRequest == nil })
        #expect(scribeCalls.count == 1)
        #expect(scribeCalls.first?.attempt == 1)
        #expect(scribeCalls.first?.status == 200)
        #expect(scribeCalls.first?.hedgeFired == false)
        #expect(scribeCalls.first?.winningRequest == 1)

        let groqRequests = await transport.groqRequests
        let scribeRequests = await transport.scribeRequests
        #expect(groqRequests.count == 2)
        #expect(scribeRequests.count == 1)

        let scribeReq = try #require(scribeRequests.first?.request)
        #expect(scribeReq.url == URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        #expect(scribeReq.httpMethod == "POST")
        #expect(scribeReq.timeoutInterval == 30)
        #expect(scribeReq.value(forHTTPHeaderField: "xi-api-key") == "scribe-api-key-123")
        #expect(scribeReq.value(forHTTPHeaderField: "Authorization") == nil)

        let scribeBody = try #require(scribeReq.httpBody)
        let scribeText = String(decoding: scribeBody, as: UTF8.self)
        #expect(scribeText.contains("name=\"model_id\"\r\n\r\nscribe_v1\r\n"))
        #expect(scribeText.contains("name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(!scribeText.contains("name=\"prompt\""))
        #expect(!scribeText.contains("name=\"response_format\""))
        #expect(!scribeText.contains("name=\"model\""))
        #expect(!scribeText.contains("Kubernetes"))

        // Exact same encoded WAV payload as Groq, no rechunking.
        let groqWAV = try #require(groqRequests.first?.wavData)
        let scribeWAV = try #require(scribeRequests.first?.wavData)
        #expect(scribeWAV == groqWAV)
    }

    @Test func scribeRetriesOnceAndCapsAtTwoAttempts() async {
        let transport = ScribeFakeTransport(
            groqByTag: [1000: [.status(403), .status(403)]],
            scribeByTag: [1000: [.status(503), .json("scribe second attempt wins")]]
        )
        let engine = GroqChunkedTranscriber(
            transport: transport,
            apiKey: { "groq-key" },
            prompt: "",
            fillerLeadIn: false,
            hedgeAfterMs: 60_000,
            edgeGuard: false,
            scribeAPIKey: { "scribe-key" }
        )
        engine.submit(speechChunk(0, tag: 1000))
        let result = await engine.finish()

        #expect(result.text == "scribe second attempt wins")
        #expect(result.scribeChunks == 1)
        #expect(result.failedCount == 0)
        #expect(await transport.scribeRequests.count == 2)
        let scribeCalls = result.calls.filter { $0.model == "scribe_v1" }
        #expect(scribeCalls.map(\.attempt) == [1, 2])
        #expect(scribeCalls.map(\.status) == [503, 200])
    }

    @Test(arguments: ["http500", "malformed", "empty"])
    func scribeFailureModesYieldFailedCountOneAfterTwoAttempts(mode: String) async {
        let scribeReply: ScribeFakeTransport.Reply
        switch mode {
        case "http500":
            scribeReply = .status(500)
        case "malformed":
            scribeReply = .raw("not valid json", status: 200)
        default:
            scribeReply = .json("   \n\t ", status: 200)
        }
        let transport = ScribeFakeTransport(
            groqByTag: [1000: [.status(403), .status(403)]],
            scribeByTag: [1000: [scribeReply, scribeReply]]
        )
        let engine = GroqChunkedTranscriber(
            transport: transport,
            apiKey: { "groq-key" },
            prompt: "",
            fillerLeadIn: false,
            hedgeAfterMs: 60_000,
            edgeGuard: false,
            scribeAPIKey: { "scribe-key" }
        )
        engine.submit(speechChunk(0, tag: 1000))
        let result = await engine.finish()

        #expect(result.failedCount == 1)
        #expect(result.scribeChunks == 0)
        #expect(result.scribeNoKey == false)
        #expect(result.text.isEmpty)
        #expect(await transport.groqRequests.count == 2)
        #expect(await transport.scribeRequests.count == 2)
        let scribeCalls = result.calls.filter { $0.model == "scribe_v1" }
        #expect(scribeCalls.count == 2)
        #expect(scribeCalls.allSatisfy { $0.winningRequest == nil && !$0.hedgeFired })
    }

    @Test(arguments: ["empty_string", "throwing"])
    func noScribeKeySkipsScribeRequestsAndSetsScribeNoKey(mode: String) async {
        let transport = ScribeFakeTransport(
            groqByTag: [1000: [.status(403), .status(403)]]
        )
        let keyClosure: @Sendable () throws -> String = {
            if mode == "throwing" { throw TranscriptionError.missingKey }
            return "   \n "
        }
        let engine = GroqChunkedTranscriber(
            transport: transport,
            apiKey: { "groq-key" },
            prompt: "",
            fillerLeadIn: false,
            hedgeAfterMs: 60_000,
            edgeGuard: false,
            scribeAPIKey: keyClosure
        )
        engine.submit(speechChunk(0, tag: 1000))
        let result = await engine.finish()

        #expect(result.failedCount == 1)
        #expect(result.scribeNoKey == true)
        #expect(result.scribeChunks == 0)
        #expect(result.text.isEmpty)
        #expect(await transport.groqRequests.count == 2)
        #expect(await transport.scribeRequests.isEmpty)
    }

    @Test func groq200PositiveControlDoesNotReadScribeKeyOrSendScribeRequests() async {
        let transport = ScribeFakeTransport(
            groqByTag: [1000: [.json("groq primary success")]]
        )
        let keyReads = LockedCounter()
        let engine = GroqChunkedTranscriber(
            transport: transport,
            apiKey: { "groq-key" },
            prompt: "Acme",
            fillerLeadIn: false,
            hedgeAfterMs: 60_000,
            edgeGuard: false,
            scribeAPIKey: {
                _ = keyReads.increment()
                return "scribe-key"
            }
        )
        engine.submit(speechChunk(0, tag: 1000))
        let result = await engine.finish()

        #expect(result.text == "groq primary success")
        #expect(result.failedCount == 0)
        #expect(result.scribeChunks == 0)
        #expect(result.scribeNoKey == false)
        #expect(keyReads.count == 0)
        #expect(await transport.groqRequests.count == 1)
        #expect(await transport.scribeRequests.isEmpty)
    }

    @Test func outOfOrderChunksPreserveAudioPayloadsBoundaryCountsAndTextOrder() async throws {
        // Chunk 0 (2,400 samples, tag 1000) finishes Scribe AFTER Chunk 1 (3,600 samples, tag 2000).
        let transport = ScribeFakeTransport(
            groqByTag: [
                1000: [.status(403), .status(403)],
                2000: [.status(403), .status(403)],
            ],
            scribeByTag: [
                1000: [.json("first chunk ordered", delayMs: 40)],
                2000: [.json("second chunk ordered", delayMs: 0)],
            ]
        )
        let streamed = StreamRecorder()
        let engine = GroqChunkedTranscriber(
            transport: transport,
            apiKey: { "groq-key" },
            prompt: "",
            fillerLeadIn: false,
            hedgeAfterMs: 60_000,
            rejoinGuard: false,
            lowSpeechGuard: false,
            edgeGuard: false,
            scribeAPIKey: { "scribe-key" },
            onChunkText: { index, text in streamed.record(index, text) }
        )

        let chunk0 = speechChunk(0, tag: 1000, sampleCount: 2_400)
        let chunk1 = speechChunk(1, tag: 2000, sampleCount: 3_600)
        engine.submit(chunk0)
        engine.submit(chunk1, isFinal: true)
        let result = await engine.finish()

        #expect(result.chunks == 2)
        #expect(result.scribeChunks == 2)
        #expect(result.scribeNoKey == false)
        #expect(result.failedCount == 0)
        #expect(result.text == "first chunk ordered second chunk ordered")

        // Verify chunk 1 completed before chunk 0 at Scribe transport level (out-of-order).
        let scribeCompletions = await transport.completionOrder.filter { $0.isScribe }.compactMap(\.tag)
        #expect(scribeCompletions == [2000, 1000])
        #expect(streamed.events.map(\.0) == [1, 0])

        // Verify each chunk's Scribe WAV payload matches its Groq WAV payload and expected resampled size.
        let groqReqs = await transport.groqRequests
        let scribeReqs = await transport.scribeRequests
        #expect(groqReqs.count == 4)
        #expect(scribeReqs.count == 2)

        let expectedWAV0 = WAVEncoder.encode(samples: GroqChunkedTranscriber.resampleTo16k(chunk0.samples), sampleRate: 16_000)
        let expectedWAV1 = WAVEncoder.encode(samples: GroqChunkedTranscriber.resampleTo16k(chunk1.samples), sampleRate: 16_000)
        let scribe0 = try #require(scribeReqs.first { $0.tag == 1000 })
        let scribe1 = try #require(scribeReqs.first { $0.tag == 2000 })
        let groq0 = try #require(groqReqs.first { $0.tag == 1000 })
        let groq1 = try #require(groqReqs.first { $0.tag == 2000 })

        #expect(scribe0.wavData == expectedWAV0)
        #expect(scribe1.wavData == expectedWAV1)
        #expect(scribe0.wavData == groq0.wavData)
        #expect(scribe1.wavData == groq1.wavData)
    }

    @Test func repetitionGuardAndNoScribeRejoinAndCancellationOnScribeFallback() async {
        // 1) RepetitionGuard collapses a Whisper/Scribe loop and updates droppedLoops before streaming.
        let loopPhrase = Array(repeating: "testing loop phrase", count: 12).joined(separator: " ")
        let transport1 = ScribeFakeTransport(
            groqByTag: [1000: [.status(403), .status(403)], 2000: [.status(403), .status(403)]],
            scribeByTag: [
                1000: [.json("and uh " + loopPhrase)],
                2000: [.json("other screenshots here")],
            ]
        )
        let streamed1 = StreamRecorder()
        let engine1 = GroqChunkedTranscriber(
            transport: transport1,
            apiKey: { "groq-key" },
            prompt: "",
            fillerLeadIn: false,
            hedgeAfterMs: 60_000,
            rejoinGuard: true,
            lowSpeechGuard: false,
            edgeGuard: false,
            scribeAPIKey: { "scribe-key" },
            onChunkText: { index, text in streamed1.record(index, text) }
        )
        engine1.submit(speechChunk(0, tag: 1000, cutKind: .pause, quietRunMs: 150))
        engine1.submit(speechChunk(1, tag: 2000), isFinal: true)
        let result1 = await engine1.finish()

        #expect(result1.scribeChunks == 2)
        #expect(result1.failedCount == 0)
        #expect(result1.droppedLoops >= 1)
        #expect(!result1.text.contains(loopPhrase))
        #expect(result1.text.contains("other screenshots here"))
        // Rejoin request fails on Groq (403) and must NOT trigger a 3rd Scribe request; existing pieces kept.
        #expect(await transport1.scribeRequests.count == 2)
        #expect(streamed1.events.count == 2)

        // 2) Cancellation while Scribe is in flight prevents late publication.
        let transport2 = ScribeFakeTransport(
            groqByTag: [3000: [.status(403), .status(403)]],
            scribeByTag: [3000: [.json("late text after cancel", delayMs: 80)]]
        )
        let streamed2 = StreamRecorder()
        let engine2 = GroqChunkedTranscriber(
            transport: transport2,
            apiKey: { "groq-key" },
            prompt: "",
            fillerLeadIn: false,
            hedgeAfterMs: 60_000,
            edgeGuard: false,
            scribeAPIKey: { "scribe-key" },
            onChunkText: { index, text in streamed2.record(index, text) }
        )
        engine2.submit(speechChunk(0, tag: 3000))
        for _ in 0..<100 where await transport2.scribeRequests.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
        engine2.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        let result2 = await engine2.finish()
        #expect(streamed2.events.isEmpty)
        #expect(result2.text.isEmpty)
    }
}
