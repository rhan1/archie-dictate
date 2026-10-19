// Fixtures are hand-written from Deepgram's documented Results shape; no live key or capture was available.
import Foundation
import Testing
import DictateCore

private final class ScriptedSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String] = []
    private var pending: CheckedContinuation<String?, Error>?
    private var closed = false
    private var binary: [Data] = []
    private var controls: [String] = []
    var late: [String] = []
    var endAfterClose = true
    var throwOnSend = false
    var sent: [Data] { lock.withLock { binary } }
    var closeStreams: Int { lock.withLock { controls.filter { $0 == DeepgramStreamingTranscriber.closeStream }.count } }

    func send(_ data: Data) async throws {
        lock.withLock { binary.append(data) }
        if throwOnSend { throw URLError(.networkConnectionLost) }
    }
    func send(_ text: String) async throws {
        lock.withLock { controls.append(text) }
        for frame in late { push(frame) }
        if endAfterClose { close() }
    }
    func receive() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !frames.isEmpty {
                let frame = frames.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else if closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                pending = continuation
                lock.unlock()
            }
        }
    }
    func push(_ frame: String) {
        let waiter = lock.withLock { () -> CheckedContinuation<String?, Error>? in
            if let waiter = pending { pending = nil; return waiter }
            frames.append(frame)
            return nil
        }
        waiter?.resume(returning: frame)
    }
    func breakSocket() {
        let waiter = lock.withLock { () -> CheckedContinuation<String?, Error>? in
            closed = true
            defer { pending = nil }
            return pending
        }
        waiter?.resume(throwing: URLError(.networkConnectionLost))
    }
    func close() {
        let waiter = lock.withLock { () -> CheckedContinuation<String?, Error>? in
            closed = true
            defer { pending = nil }
            return pending
        }
        waiter?.resume(returning: nil)
    }
}

private final class ScriptedWebSocket: WebSocketTransport, @unchecked Sendable {
    let socket: ScriptedSocket
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var failConnect = false
    var count: Int { lock.withLock { requests.count } }
    init(_ socket: ScriptedSocket = ScriptedSocket()) { self.socket = socket }
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        lock.withLock { requests.append(request) }
        if failConnect { throw URLError(.cannotConnectToHost) }
        return socket
    }
}

private final class ChunkTexts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, String)] = []
    func append(_ index: Int, _ text: String) { lock.withLock { values.append((index, text)) } }
    var texts: [String] { lock.withLock { values.map(\.1) } }
    var indices: [Int] { lock.withLock { values.map(\.0) } }
}

private final class WholeWAVTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { storage } }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { storage.append(request) }
        return (Data("{\"text\":\"Recovered entire dictation.\"}".utf8),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func eventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return predicate()
}

@Suite("DeepgramStreamingTranscriberTests")
struct DeepgramStreamingTranscriberTests {
    private func fixture() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/deepgram-nova3-frames.jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func finalsBeforeStopAndLateFinal() async throws {
        let frames = try fixture()
        let socket = ScriptedSocket()
        let transport = ScriptedWebSocket(socket)
        let texts = ChunkTexts()
        let clock = ManualClock()
        socket.endAfterClose = false
        let whole = WholeWAVTransport()
        let engine = DeepgramStreamingTranscriber(transport: transport, apiKey: { "scripted-key" },
            clock: clock, fallbackClient: TranscriptionClient(transport: whole, apiKey: { "fake" }),
            onChunkText: { texts.append($0, $1) })
        engine.append([1, -2, 32767])
        #expect(await eventually { socket.sent.count == 1 })
        #expect(socket.sent == [Data([1, 0, 254, 255, 255, 127])])
        for frame in frames.prefix(4) { socket.push(frame) }
        // Positive control: a real final must arrive while finish has never been called.
        #expect(await eventually { texts.texts == ["Send the report."] })
        let finishing = Task { await engine.finish() }
        #expect(await eventually { socket.closeStreams == 1 && clock.sleepers >= 2 })
        clock.advance(by: .milliseconds(1200))
        socket.push(frames[4])
        socket.close()
        let result = await finishing.value
        #expect(result.text == "Send the report. On Wednesday.")
        #expect(result.chunks == 2 && result.failedCount == 0)
        #expect(texts.indices == [0, 1])
        #expect(whole.requests.isEmpty)
        // Negative controls: both interim frames and the whitespace final must be rejected.
        #expect(!texts.texts.contains("unfinished preview"))
        #expect(!texts.texts.contains("another preview"))
        print("ST1 GREEN finals=2 before_stop=1 late_final=1 interim_ignored=2")
    }

    @Test func keytermsThree() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("terms.txt")
        try "Limpar\n\nACME & Sons\nCafé/東京".write(to: url, atomically: true, encoding: .utf8)
        let request = DeepgramStreamingTranscriber.makeRequest(apiKey: "fake", keytermsURL: url)
        let raw = try #require(request.url?.absoluteString)
        #expect(raw == DeepgramStreamingTranscriber.listenURL + "&keyterm=Limpar&keyterm=ACME%20%26%20Sons&keyterm=Caf%C3%A9%2F%E6%9D%B1%E4%BA%AC")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token fake")
        let query = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.filter { $0.name == "keyterm" }.count == 3)
        #expect(DeepgramStreamingTranscriber.makeRequest(apiKey: "fake", keytermsURL: folder.appendingPathComponent("absent")).url?.absoluteString == DeepgramStreamingTranscriber.listenURL)
        #expect(AppPaths(home: folder).keytermsURL == folder.appendingPathComponent(".claude/dictate/keyterms.txt"))
        print("ST1 URL keyterms=3 model=nova-3 sample_rate=24000")
    }

    @Test func keytermsCap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try (1...60).map { "Term \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let request = DeepgramStreamingTranscriber.makeRequest(apiKey: "fake", keytermsURL: url)
        let terms = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems).filter { $0.name == "keyterm" }
        #expect(terms.count == 50)
        #expect(terms.last?.value == "Term 50")
        #expect(!terms.contains { $0.value == "Term 51" })
        print("ST1 URL keyterms=50 model=nova-3 sample_rate=24000")
    }

    @Test func closeDeadline() async throws {
        let clock = ManualClock()
        let socket = ScriptedSocket()
        socket.endAfterClose = false
        let texts = ChunkTexts()
        let engine = DeepgramStreamingTranscriber(transport: ScriptedWebSocket(socket), apiKey: { "fake" },
            clock: clock, onChunkText: { texts.append($0, $1) })
        engine.append([42])
        #expect(await eventually { socket.sent.count == 1 })
        socket.push(try fixture()[1])
        #expect(await eventually { texts.texts.count == 1 })
        let finish = Task { await engine.finish() }
        #expect(await eventually { socket.closeStreams == 1 && clock.sleepers >= 2 })
        clock.advance(by: .milliseconds(1499))
        #expect(socket.closeStreams == 1)
        clock.advance(by: .milliseconds(1))
        let result = await finish.value
        #expect(result.text == "Send the report." && result.failedCount == 0)
        #expect(clock.elapsed == .milliseconds(1500))
        let repeated = await engine.finish()
        #expect(repeated.text == result.text && socket.closeStreams == 1)
        print("ST1 CLOSE closestream=1 waited_ms<=1500")
    }
    private func verifyFallback(_ reason: String) async throws {
        let clock = ManualClock()
        let socket = ScriptedSocket()
        let transport = ScriptedWebSocket(socket)
        transport.failConnect = reason == "connect"
        let http = WholeWAVTransport()
        let notes = ChunkTexts()
        let texts = ChunkTexts()
        let engine = DeepgramStreamingTranscriber(transport: transport, apiKey: {
            if reason == "missing_key" { throw TranscriptionError.missingKey }
            return "scripted-key"
        }, clock: clock, fallbackClient: TranscriptionClient(transport: http, apiKey: { "fake-groq" }),
           prompt: "fixture vocabulary", note: { notes.append(0, $0) },
           onChunkText: { texts.append($0, $1) })
        engine.append([1, -2])
        if reason == "socket" || reason == "timeout" {
            #expect(await eventually { socket.sent.count == 1 && clock.sleepers >= 1 })
            socket.push(try fixture()[1])
            #expect(await eventually { texts.texts.count == 1 })
            if reason == "socket" { socket.breakSocket() }
            else { clock.advance(by: .seconds(15)) }
        }
        #expect(await eventually { engine.fallbackReason == reason })
        // More audio arrives after the failure: the fallback must include it as well.
        engine.append([3, 4])
        let expectedPCM: [Int16]
        if reason == "socket" {
            expectedPCM = [100, 200, 300, 400, 500]
            engine.setFallbackPCM(expectedPCM) // recorder's authoritative retained capture
        } else { expectedPCM = [1, -2, 3, 4] }
        async let a = engine.finish()
        async let b = engine.finish()
        let (first, second) = await (a, b)
        #expect(first.text == "Recovered entire dictation." && first.failedCount == 0)
        #expect(second.text == first.text)
        #expect(http.requests.count == 1)
        #expect(socket.closeStreams == 0)
        #expect(notes.texts == ["stt_fallback=groq reason=\(reason)"])
        #expect(transport.count == (reason == "missing_key" ? 0 : 1))
        let request = try #require(http.requests.first)
        #expect(request.url == TranscriptionClient.groqEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-groq")
        let body = try #require(request.httpBody)
        let wav = WAVEncoder.encode(samples: expectedPCM, sampleRate: 24_000)
        #expect(body.range(of: wav) != nil)
        #expect(String(decoding: body, as: UTF8.self).contains("fixture vocabulary"))
        // Whole-WAV replacement must not append a duplicate after the partial streaming final.
        #expect(!texts.texts.contains("Recovered entire dictation."))
    }

    @Test func socketFallback() async throws {
        try await verifyFallback("socket")
        print("ST1 FALLBACK reason=socket groq_requests=1 lost=0")
    }

    @Test func missingKeyFallback() async throws {
        try await verifyFallback("missing_key")
        print("ST1 FALLBACK reason=missing_key groq_requests=1 lost=0")
    }

    @Test func connectFallback() async throws {
        try await verifyFallback("connect")
        print("ST1 FALLBACK reason=connect groq_requests=1 lost=0")
    }

    @Test func timeoutFallback() async throws {
        try await verifyFallback("timeout")
        print("ST1 FALLBACK reason=timeout groq_requests=1 lost=0")
    }

    @Test func cancelledRunDoesNotFallback() async {
        let socket = ScriptedSocket()
        let http = WholeWAVTransport()
        let engine = DeepgramStreamingTranscriber(transport: ScriptedWebSocket(socket), apiKey: { "fake" },
            clock: ManualClock(), fallbackClient: TranscriptionClient(transport: http, apiKey: { "fake" }))
        engine.append([1])
        #expect(await eventually { socket.sent.count == 1 })
        engine.cancel()
        let result = await engine.finish()
        #expect(result.failedCount == 1 && result.text.isEmpty)
        #expect(http.requests.isEmpty && socket.closeStreams == 0)
        print("ST1 CANCEL groq_requests=0 closestream=0")
    }

}
