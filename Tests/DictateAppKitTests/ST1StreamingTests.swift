// SYNTHETIC provider frames: every Deepgram frame in these tests (Fixtures/deepgram-nova3-frames.jsonl and
// `Frames.final`) is hand-written from Deepgram's documented live `Results`/`Metadata` shape. No key exists to
// capture real frames, so the provider schema is UNVERIFIED. No network, no Keychain, no audio devices:
// every socket, HTTP call, key reader, recorder, inserter and deadline below is a fake or a virtual clock.
import AppKit
import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

// MARK: - Fakes shared by the unit and host suites

/// Thread-safe value box for counters observed from transport/receiver tasks.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

private enum Frames {
    static let lines: [String] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/deepgram-nova3-frames.jsonl")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }()
    static var header: String { lines.first ?? "" }
    static var frames: [String] { lines.filter { !$0.hasPrefix("#") } }
    static var interimAlpha: String { frames[0] }
    static var finalAlpha: String { frames[1] }
    static var duplicateAlpha: String { frames[2] }
    static var finalBeta: String { frames[3] }
    static var metadata: String { frames[4] }
    /// The documented final-frame shape (anchored to the fixture's final alpha by a test).
    static func final(_ transcript: String, start: Double, duration: Double, speechFinal: Bool = false) -> String {
        "{\"type\":\"Results\",\"channel_index\":[0,1],\"start\":\(String(format: "%.1f", start)),\"duration\":\(String(format: "%.1f", duration)),"
            + "\"is_final\":true,\"speech_final\":\(speechFinal),\"channel\":{\"alternatives\":[{\"transcript\":\"\(transcript)\",\"confidence\":0.99,\"words\":[]}]}}"
    }
}

/// One scripted socket. `idle` = a receive is pending with nothing queued: every pushed frame was consumed.
private final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [String] = []
    private var pending: CheckedContinuation<String?, Error>?
    private var closed = false
    private var binary: [Data] = []
    private var texts: [String] = []
    private var clientCloses = 0
    var failSends = false

    func send(_ data: Data) async throws {
        lock.withLock { binary.append(data) }
        if failSends { throw URLError(.networkConnectionLost) }
    }
    func send(_ text: String) async throws { lock.withLock { texts.append(text) } }
    func receive() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queued.isEmpty {
                let frame = queued.removeFirst()
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
            queued.append(frame)
            return nil
        }
        waiter?.resume(returning: frame)
    }
    /// The server ends the stream with a normal close.
    func serverClose() { end(nil) }
    func breakSocket() { end(URLError(.networkConnectionLost)) }
    func close() {
        lock.withLock { clientCloses += 1 }
        end(nil)
    }
    private func end(_ error: Error?) {
        let waiter = lock.withLock { () -> CheckedContinuation<String?, Error>? in
            closed = true
            defer { pending = nil }
            return pending
        }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
    }
    var idle: Bool { lock.withLock { pending != nil && queued.isEmpty } }
    var sent: [Data] { lock.withLock { binary } }
    var closeStreams: Int { lock.withLock { texts.filter { $0 == DeepgramStreamingTranscriber.closeStream }.count } }
    var closedByClient: Bool { lock.withLock { clientCloses > 0 } }
}

/// A new socket per connect, like a real WebSocket transport.
private final class FakeWSTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [FakeSocket] = []
    private var requestList: [URLRequest] = []
    var failConnect = false
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        lock.withLock { requestList.append(request) }
        if failConnect { throw URLError(.cannotConnectToHost) }
        let socket = FakeSocket()
        lock.withLock { opened.append(socket) }
        return socket
    }
    var connects: Int { lock.withLock { opened.count } }
    var requests: [URLRequest] { lock.withLock { requestList } }
    func socket(_ index: Int) -> FakeSocket? { lock.withLock { index < opened.count ? opened[index] : nil } }
}

private func eventually(seconds: Double = 10, _ predicate: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return predicate()
}

// MARK: - Unit: the Deepgram session, request, selection, policy, WER

@Suite("DeepgramStreamingTranscriberTests")
struct DeepgramStreamingTranscriberTests {
    private final class Segments: @unchecked Sendable {
        let box = Box<[(Int, String)]>([])
        func add(_ index: Int, _ text: String) { box.mutate { $0.append((index, text)) } }
        var texts: [String] { box.value.map(\.1) }
        var indexes: [Int] { box.value.map(\.0) }
    }

    @Test func fixtureIsLabeledSyntheticAndAnchorsTheFrameShape() {
        #expect(Frames.header.hasPrefix("# SYNTHETIC"))
        #expect(Frames.frames.count == 5)
        // The contract's final-frame shape, byte for byte; the helper reproduces it.
        #expect(Frames.finalAlpha == #"{"type":"Results","channel_index":[0,1],"start":0.0,"duration":0.5,"is_final":true,"speech_final":false,"channel":{"alternatives":[{"transcript":"alpha","confidence":0.99,"words":[]}]}}"#)
        #expect(Frames.final("alpha", start: 0, duration: 0.5) == Frames.finalAlpha)
    }

    @Test func requestUsesURLComponentsRepeatedEncodedKeytermsNewestFiftyAndTokenAuth() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("st1-terms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("small.txt")
        try "Limpar\n\nACME & Sons\nCafé/東京\n".write(to: small, atomically: true, encoding: .utf8)
        let request = DeepgramStreamingTranscriber.makeRequest(apiKey: "fake-key", keytermsURL: small)
        let url = try #require(request.url)
        #expect(url.absoluteString == "wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=24000&channels=1"
            + "&interim_results=true&smart_format=true&punctuate=true"
            + "&keyterm=Limpar&keyterm=ACME%20%26%20Sons&keyterm=Caf%C3%A9%2F%E6%9D%B1%E4%BA%AC")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.filter { $0.name == "keyterm" }.map(\.value) == ["Limpar", "ACME & Sons", "Café/東京"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token fake-key")
        // Newest 50: ST2 appends newest-last, so lines 11...60 of 60 survive.
        let big = folder.appendingPathComponent("big.txt")
        try (1...60).map { "Term \($0)" }.joined(separator: "\n").write(to: big, atomically: true, encoding: .utf8)
        let terms = try #require(URLComponents(url: DeepgramStreamingTranscriber.makeRequest(apiKey: "k", keytermsURL: big).url!,
                                               resolvingAgainstBaseURL: false)?.queryItems).filter { $0.name == "keyterm" }
        #expect(terms.count == 50 && terms.first?.value == "Term 11" && terms.last?.value == "Term 60")
        // Missing file: no keyterm at all.
        let none = DeepgramStreamingTranscriber.makeRequest(apiKey: "k", keytermsURL: folder.appendingPathComponent("absent.txt"))
        #expect(none.url?.absoluteString.contains("keyterm") == false)
        #expect(AppPaths(home: folder).keytermsURL == folder.appendingPathComponent(".claude/dictate/keyterms.txt"))
    }

    @Test func wireFormatIsRawLittleEndianInt16WithoutHeader() async {
        let transport = FakeWSTransport()
        let session = DeepgramStreamingTranscriber(transport: transport, apiKey: { "k" }, clock: ManualClock())
        session.append([1, -2, 32767])
        #expect(await eventually { transport.socket(0)?.sent.count == 1 })
        #expect(transport.socket(0)?.sent == [Data([1, 0, 254, 255, 255, 127])])
        #expect(DeepgramStreamingTranscriber.linear16([0x1234]) == Data([0x34, 0x12]))
        session.cancel()
    }

    @Test func finalsOnlyDuplicatesFilteredContiguousIndexesAndMetadataTerminal() async throws {
        let transport = FakeWSTransport()
        let clock = ManualClock()
        let segments = Segments()
        let session = DeepgramStreamingTranscriber(transport: transport, apiKey: { "k" }, clock: clock,
            onFinalSegment: { segments.add($0, $1) })
        session.append([7])
        #expect(await eventually { transport.socket(0)?.idle == true })
        let socket = try #require(transport.socket(0))
        for frame in [Frames.interimAlpha, Frames.finalAlpha, Frames.duplicateAlpha] {
            socket.push(frame)
            #expect(await eventually { socket.idle })
        }
        #expect(segments.texts == ["alpha"])   // interim and duplicate never reach the pipeline
        let finishing = Task { await session.finish() }
        #expect(await eventually { socket.closeStreams == 1 })
        socket.push(Frames.finalBeta)
        #expect(await eventually { segments.texts.count == 2 })
        socket.push(Frames.metadata)
        let result = await finishing.value
        #expect(result.complete && result.text == "alpha beta" && result.finalSegments == 2)
        #expect(segments.indexes == [0, 1])
        #expect(result.diagnostics.interimFrames == 1 && result.diagnostics.duplicateFinals == 1)
        #expect(result.diagnostics.finalsBeforeStop == 1 && result.diagnostics.lateFinals == 1)
        #expect(result.diagnostics.connects == 1 && result.diagnostics.closeStreams == 1 && result.diagnostics.terminalMs == 0)
        // Idempotent finish: the same result, no second CloseStream.
        #expect(await session.finish() == result && socket.closeStreams == 1)
    }

    @Test func terminalDeadlineIsInclusiveAt1500AndIncompleteAt1501WithNoStaleCallbacks() async throws {
        let transport = FakeWSTransport()
        let clock = ManualClock()
        let segments = Segments()
        let failures = Box<[String]>([])
        let session = DeepgramStreamingTranscriber(transport: transport, apiKey: { "k" }, clock: clock,
            onFinalSegment: { segments.add($0, $1) }, onFailure: { reason in failures.mutate { $0.append(reason) } })
        session.append([7])
        #expect(await eventually { transport.socket(0)?.idle == true })
        let socket = try #require(transport.socket(0))
        socket.push(Frames.finalAlpha)
        #expect(await eventually { segments.texts.count == 1 })
        let finishing = Task { await session.finish() }
        #expect(await eventually { socket.closeStreams == 1 && clock.sleepers >= 2 })
        clock.advance(by: .milliseconds(1500))
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(failures.value.isEmpty && !socket.closedByClient)   // 1500 ms is still inside the wait
        clock.advance(by: .milliseconds(1))
        let result = await finishing.value
        #expect(!result.complete && result.diagnostics.failureReason == "terminal_timeout")
        #expect(failures.value == ["terminal_timeout"] && socket.closedByClient)
        socket.push(Frames.finalBeta)   // stale: after the deadline
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(segments.texts == ["alpha"])
    }

    private func failedSession(_ reason: String) async throws -> (StreamingSTTResult, [String], Int) {
        let transport = FakeWSTransport()
        transport.failConnect = reason == "connect"
        let clock = ManualClock()
        let failures = Box<[String]>([])
        let session = DeepgramStreamingTranscriber(transport: transport, apiKey: {
            if reason == "missing_key" { throw TranscriptionError.missingKey }
            return "k"
        }, clock: clock, receiveTimeout: .seconds(15), onFailure: { r in failures.mutate { $0.append(r) } })
        session.append([7])
        if ["socket", "timeout", "socket_after_stop"].contains(reason) {
            #expect(await eventually { transport.socket(0)?.idle == true && clock.sleepers >= 1 })
            let socket = try #require(transport.socket(0))
            switch reason {
            case "socket": socket.breakSocket()
            case "timeout": clock.advance(by: .seconds(15))
            default:
                let finishing = Task { await session.finish() }
                #expect(await eventually { socket.closeStreams == 1 })
                socket.breakSocket()
                return (await finishing.value, failures.value, transport.connects)
            }
        }
        #expect(await eventually { !failures.value.isEmpty })
        session.append([8])   // ignored after failure
        return (await session.finish(), failures.value, transport.connects)
    }

    @Test func everyFailureIsIncompleteWithOneReason() async throws {
        for (reason, expected, connects) in [("missing_key", "missing_key", 0), ("connect", "connect", 0),
                                             ("socket", "socket", 1), ("timeout", "timeout", 1),
                                             ("socket_after_stop", "socket", 1)] {
            let (result, failures, opened) = try await failedSession(reason)
            #expect(!result.complete, "\(reason)")
            #expect(result.diagnostics.failureReason == expected, "\(reason)")
            #expect(failures == [expected], "\(reason)")
            #expect(opened == connects, "\(reason)")
        }
    }

    @Test func cancelStopsCallbacksAndNeverSendsCloseStream() async throws {
        let transport = FakeWSTransport()
        let segments = Segments()
        let session = DeepgramStreamingTranscriber(transport: transport, apiKey: { "k" }, clock: ManualClock(),
            onFinalSegment: { segments.add($0, $1) })
        session.append([7])
        #expect(await eventually { transport.socket(0)?.idle == true })
        let socket = try #require(transport.socket(0))
        session.cancel()
        socket.push(Frames.finalAlpha)
        let result = await session.finish()
        #expect(!result.complete && result.diagnostics.failureReason == "cancelled")
        #expect(segments.texts.isEmpty && socket.closeStreams == 0 && socket.closedByClient)
    }

    @Test func stopPhraseSplitAcrossSegmentsIsHeardOnceAndOnlyAsItsOwnSentence() {
        let split = StreamingStopPhrase()
        #expect(split.append("stop") == false)
        #expect(split.append("dictation") == true)
        #expect(split.append("dictation") == false)   // once
        let afterSentence = StreamingStopPhrase()
        #expect([afterSentence.append("Send the report."), afterSentence.append("Stop"), afterSentence.append("dictation.")] == [false, false, true])
        let mentioned = StreamingStopPhrase()
        #expect([mentioned.append("I told him to"), mentioned.append("stop"), mentioned.append("dictation")] == [false, false, false])
        // Negative control for the retained suffix: per-segment checking alone misses the split phrase.
        #expect(!TrailingStopPhrase.endsDictation("stop") && !TrailingStopPhrase.endsDictation("dictation"))
    }

    @Test func werScorerControls() {
        for (ref, hyp) in [("alpha beta", "alpha beta"), ("alpha beta", "alpha gamma extra")] {
            let score = WordErrorRate.score(reference: ref, hypothesis: hyp)
            print("ST1 WER CONTROL ref=\"\(ref)\" hyp=\"\(hyp)\" \(score.line)")
        }
        #expect(WordErrorRate.score(reference: "alpha beta", hypothesis: "alpha beta").line == "S=0 D=0 I=0 N=2 WER=0.000000")
        #expect(WordErrorRate.score(reference: "alpha beta", hypothesis: "alpha gamma extra").line == "S=1 D=0 I=1 N=2 WER=1.000000")
        #expect(WordErrorRate.score(reference: "Alpha, beta-gamma!", hypothesis: "alpha beta").line == "S=0 D=1 I=0 N=3 WER=0.333333")
        #expect(WordErrorRate.words("Don't STOP—now") == ["don", "t", "stop", "now"])
    }

    @Test @MainActor func selectionDefaultsToGroqAndAnExplicitChoiceSurvivesADefaultChange() {
        #expect(DictationSTT.default == .groqChunked)
        #expect(DictationSTT.resolve(nil) == .groqChunked)
        #expect(DictationSTT.resolve("junk") == .groqChunked)
        #expect(DictationSTT.resolve(" Deepgram ") == .deepgramStreaming)
        #expect(DictationSTT.resolve("groq", default: .deepgramStreaming) == .groqChunked)
        #expect(DictationSTT.resolve(nil, default: .deepgramStreaming) == .deepgramStreaming)
        #expect(DictationSTT.preferenceKey == "DictationSTT" && DictationSTT.deepgramKeyService == "deepgram-api")
        // Construction only: no start, no key read, no socket.
        let keys = KeyStore(reader: { _ in Issue.record("selection must not read keys"); throw TranscriptionError.missingKey })
        let paths = AppPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("st1-select-\(UUID().uuidString)"))
        let quota = paths.mutedStateURL.deletingLastPathComponent().appendingPathComponent("q.json")
        #expect(DictationEngine(keyStore: keys, paths: paths, surface: .none, quotaFileURL: quota).stt == .groqChunked)
        #expect(DictationEngine(keyStore: keys, paths: paths, surface: .none, quotaFileURL: quota, stt: .deepgramStreaming).stt == .deepgramStreaming)
        let explicitGroq = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate, quotaFileURL: quota,
                                         stt: .groqChunked, defaultSTT: .deepgramStreaming)
        let unstated = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate, quotaFileURL: quota,
                                     defaultSTT: .deepgramStreaming)
        #expect(explicitGroq.dictationSTT == .groqChunked && unstated.dictationSTT == .deepgramStreaming)
    }

    private struct FakeStreaming: StreamingSTTSession {
        let result: StreamingSTTResult
        func append(_ pcm: [Int16]) {}
        func finish(at finish: DispatchTime) async -> StreamingSTTResult { result }
        func cancel() {}
    }
    private struct FakeApple: EngineAppleSession {
        let text: String
        func start() async throws {}
        func append(_ samples: [Int16]) {}
        func finish() async throws -> String { text }
        func cancel() {}
    }

    @Test func providerEligibilityIsSeparateFromGroqAndIncompleteRunsOneWholeWAV() async {
        var diagnostics = StreamingSTTResult.Diagnostics(provider: "deepgram")
        let complete = StreamingSTTResult(text: "alpha", finalSegments: 1, complete: true, diagnostics: diagnostics)
        diagnostics.failureReason = "socket"
        let broken = StreamingSTTResult(text: "alpha", finalSegments: 1, complete: false, diagnostics: diagnostics)
        // Groq key unavailable: Groq STT/cleanup are off, the Deepgram provider still runs.
        var noGroq = EnginePolicy(mode: .dictate)
        noGroq.keyUnavailable = true
        noGroq.sttProvider = .deepgramStreaming
        #expect(noGroq.usesStreamingSTT && !noGroq.usesGroqSTT && !noGroq.usesGroqCleanup)
        let wholeCalls = Box(0), incompletes = Box<[String]>([])
        let whole: @Sendable () async throws -> String = { wholeCalls.mutate { $0 += 1 }; return "whole recording" }
        let onIncomplete: @Sendable (String) -> Void = { r in incompletes.mutate { $0.append(r) } }
        let ok = await noGroq.transcribe(apple: FakeApple(text: "apple"), streaming: FakeStreaming(result: complete),
                                         at: .now(), wholeWAV: whole, onIncomplete: onIncomplete)
        #expect(ok.path == "deepgram-streaming" && (try? ok.result.get()) == "alpha" && wholeCalls.value == 0)
        #expect(EnginePolicy.isIncrementalPath(ok.path) && EnginePolicy.isIncrementalPath("groq-chunked"))
        let groqIneligible = await noGroq.transcribe(apple: FakeApple(text: "apple"), streaming: FakeStreaming(result: broken),
                                                     at: .now(), wholeWAV: whole, onIncomplete: onIncomplete)
        #expect(groqIneligible.path == "apple" && wholeCalls.value == 0 && incompletes.value == ["socket"])
        let eligible = EnginePolicy(mode: .dictate)
        let recovered = await eligible.transcribe(apple: FakeApple(text: "apple"), streaming: FakeStreaming(result: broken),
                                                  at: .now(), wholeWAV: whole, onIncomplete: onIncomplete)
        #expect(recovered.path == "groq-whole" && (try? recovered.result.get()) == "whole recording" && wholeCalls.value == 1)
        // Groq failure → the existing recovery: Apple's final, else no_stt (never a claimed transcript).
        let failing: @Sendable () async throws -> String = { throw TranscriptionError.missingKey }
        let apple = await eligible.transcribe(apple: FakeApple(text: "apple"), streaming: FakeStreaming(result: broken),
                                              at: .now(), wholeWAV: failing, onIncomplete: onIncomplete)
        #expect(apple.path == "apple" && (try? apple.result.get()) == "apple")
        let nothing = await eligible.transcribe(apple: FakeApple(text: ""), streaming: FakeStreaming(result: broken),
                                                at: .now(), wholeWAV: failing, onIncomplete: onIncomplete)
        if case .failure(let error) = nothing.result { #expect((error as? TranscriptionError)?.logReason == "rejected_no_stt") }
        else { Issue.record("expected no_stt") }
    }
}

// MARK: - Host: the real AppController/DictationEngine with fake recorder, sockets, HTTP and inserter

private final class HostPanel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) {}
    func hide() {}
    func push(level: Double) {}
}

private final class HostRecorder: EngineRecorder {
    var isRunning = false
    var onLevel: ((Double) -> Void)?
    var onPCMChunk: (([Int16]) -> Void)?
    var onFirstBuffer: (() -> Void)?
    var onCaptureFailure: ((CaptureFailure) -> Void)?
    var stats = AudioRecorder.CaptureStats()
    var ready = false
    var starts = 0
    var isAllocated = false
    var bridgeHasAudio = false
    func release() { isAllocated = false; isRunning = false }
    func start(device: MicChoice) throws { starts += 1; isAllocated = true; isRunning = true; onFirstBuffer?() }
    func startAsync(device: MicChoice) async throws { try start(device: device) }
    func rebuild() throws {}
    func rebuildAsync() async throws {}
    func resetCapture() { ready = true }
    /// Live audio for the attached transcribers.
    func feed() { onPCMChunk?([Int16](repeating: 1000, count: 2400)) }
    func stop() -> [Float] {
        isRunning = false
        onPCMChunk?([Int16](repeating: 1000, count: 9600))   // the final flush (DictationEngineTests' shape)
        return [Float](repeating: 0.1, count: 9600)
    }
}

private struct SilentApple: EngineAppleSession {
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { "" }
    func cancel() {}
}

/// Groq STT (whole-WAV / chunked) and Groq cleanup. Counts transcription and completion requests only.
private final class HostHTTP: HTTPTransport, @unchecked Sendable {
    let transcript: String
    let transcriptions = Box(0)
    let completions = Box(0)
    init(transcript: String) { self.transcript = transcript }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let payload: [String: Any]
        if path.contains("transcriptions") {
            transcriptions.mutate { $0 += 1 }
            payload = ["text": transcript]
        } else if path.contains("completions") {
            completions.mutate { $0 += 1 }
            payload = ["choices": [["finish_reason": "stop", "message": ["content": transcript]]]]
        } else {
            payload = ["data": []]   // warm-up GET /models
        }
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("ST1StreamingHostTests", .serialized) @MainActor
struct ST1StreamingHostTests {
    @MainActor fileprivate final class Host {
        let controller: AppController
        let engine: DictationEngine
        let recorder: HostRecorder
        let transport: FakeWSTransport
        let clock: ManualClock
        let http: HostHTTP
        let segmentBox: Box<[String]>
        let insertionBox: Box<[String]>
        let notes = Box<[String]>([])
        let clipboard: NSPasteboard
        let root: URL
        init(controller: AppController, engine: DictationEngine, recorder: HostRecorder, transport: FakeWSTransport,
             clock: ManualClock, http: HostHTTP, segments: Box<[String]>, insertions: Box<[String]>,
             clipboard: NSPasteboard, root: URL) {
            self.controller = controller; self.engine = engine; self.recorder = recorder; self.transport = transport
            self.clock = clock; self.http = http; segmentBox = segments; insertionBox = insertions
            self.clipboard = clipboard; self.root = root
        }
        /// Final segments the session handed the pipeline (via EngineDependencies.onStreamingSegment).
        var segments: [String] { segmentBox.value }
        /// Text the fake inserter pasted, one entry per insertion.
        var inserted: [String] { insertionBox.value }
        func noteCount(_ fragment: String) -> Int { notes.value.filter { $0.contains(fragment) }.count }
        func tearDown() {
            engine.cancel()
            AppController.setNoteSink(nil)
            clipboard.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func wait(_ what: String, seconds: Double = 10, _ predicate: () -> Bool) async throws {
        guard await eventually(seconds: seconds, predicate) else {
            Issue.record("timed out waiting for \(what)")
            throw URLError(.timedOut)
        }
    }

    /// One host driver for every receipt, old factory and new. `mutation` = the ST1 RED selector mutation.
    private func makeHost(stt: DictationSTT, mutation: Bool = false, transcript: String = "unused",
                          reader: (@Sendable (String) throws -> String)? = nil) async throws -> Host {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("st1-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = KeyStore(reader: reader ?? { _ in "fixture-key" })
        keys.prefetch(services: ["groq-api", DictationSTT.deepgramKeyService])
        try await wait("keys") { keys.missing(for: "groq-api") == nil && keys.missing(for: DictationSTT.deepgramKeyService) != .pending }
        let recorder = HostRecorder()
        let transport = FakeWSTransport()
        let clock = ManualClock()
        let http = HostHTTP(transcript: transcript)
        let clipboard = NSPasteboard(name: .init("st1-host-\(UUID().uuidString)"))
        let insertions = Box<[String]>([])
        let confirmed = Box<[String]?>(nil)
        let inserter = TextInserter(pasteboard: clipboard, postKeystroke: {
            let pasted = clipboard.string(forType: .string) ?? ""
            insertions.mutate { $0.append(pasted) }
            confirmed.mutate { $0 = [pasted] }
        }, pollInterval: 0.01, axReader: { confirmed.value })
        let segments = Box<[String]>([])
        var dependencies = EngineDependencies(recorder: recorder, makeApple: { SilentApple() }, sttTransport: http,
            groqCleanupTransport: http, localCleanupTransport: http, inserter: inserter,
            panelFactory: { HostPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.st1") }, manageMedia: false)
        dependencies.wsTransport = transport
        dependencies.streamingClock = clock
        dependencies.onStreamingSegment = { _, text in segments.mutate { $0.append(text) } }
        let paths = AppPaths(home: root)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate,
                                       dependencies: dependencies, quotaFileURL: root.appendingPathComponent("quota.json"),
                                       stt: stt, keytermsURL: root.appendingPathComponent("keyterms.txt"))
        controller.st1REDMutationForcePreST1Factory = mutation
        let engine = DictationEngine(controller: controller)
        let host = Host(controller: controller, engine: engine, recorder: recorder, transport: transport, clock: clock,
                        http: http, segments: segments, insertions: insertions, clipboard: clipboard, root: root)
        // Positive control of the insertion counter: the fake inserter fires once, then it is reset.
        inserter.insert("probe")
        try await wait("probe insertion") { insertions.value.count == 1 }
        insertions.mutate { $0.removeAll() }
        #expect(insertions.value.isEmpty)
        let notes = host.notes
        AppController.setNoteSink { line in notes.mutate { $0.append(line) } }
        return host
    }

    private func startRecording(_ host: Host) async throws {
        host.engine.start()
        try await wait("recording") { host.recorder.ready && host.recorder.starts > 0 && !host.controller.micStartPending }
        host.recorder.feed()
    }

    private func socket(_ host: Host, _ index: Int = 0) async throws -> FakeSocket {
        try await wait("socket \(index)") { host.transport.socket(index)?.idle == true }
        return host.transport.socket(index)!
    }

    struct AlphaRun { var selected: String; var effective: String; var connects: Int; var interimCallbacks: Int
                      var finalsBeforeStop: Int; var duplicateCallbacks: Int }

    /// Frames: interim alpha, final alpha, duplicate final alpha — all before stop.
    private func alphaScenario(mutation: Bool) async throws -> AlphaRun {
        let host = try await makeHost(stt: .deepgramStreaming, mutation: mutation)
        defer { host.tearDown() }
        try await startRecording(host)
        var interim = 0, before = 0, duplicates = 0
        // The old factory never opens a socket: give it the same bounded chance to.
        if await eventually(seconds: mutation ? 0.5 : 10, { host.transport.socket(0)?.idle == true }),
           let socket = host.transport.socket(0) {
            socket.push(Frames.interimAlpha)
            try await wait("interim consumed") { socket.idle }
            interim = host.segments.count
            socket.push(Frames.finalAlpha)
            try await wait("final alpha") { host.segments.count == 1 }
            socket.push(Frames.duplicateAlpha)
            try await wait("duplicate consumed") { socket.idle }
            duplicates = host.segments.count - 1
        }
        before = host.segments.count
        return AlphaRun(selected: host.controller.dictationSTT == .deepgramStreaming ? "deepgram" : "groq",
                        effective: host.controller.effectiveSTT == .deepgramStreaming ? "deepgram" : "groq",
                        connects: host.transport.connects, interimCallbacks: interim,
                        finalsBeforeStop: before, duplicateCallbacks: duplicates)
    }

    @Test(.timeLimit(.minutes(1))) func redOldFactoryThenGreenStreamingFinalsBeforeStop() async throws {
        let red = try await alphaScenario(mutation: true)
        let redPasses = red.effective == "deepgram" && red.connects == 1 && red.finalsBeforeStop == 1
        print("ST1 RED selected=\(red.selected) effective=\(red.effective) websocket_connects=\(red.connects) finals_before_stop=\(red.finalsBeforeStop) result=\(redPasses ? "PASS" : "FAIL")")
        #expect(!redPasses, "the pre-ST1 factory must fail the GREEN criteria")
        #expect(red.selected == "deepgram" && red.effective == "groq" && red.connects == 0 && red.finalsBeforeStop == 0)
        let green = try await alphaScenario(mutation: false)
        print("ST1 GREEN websocket_connects=\(green.connects) interim_callbacks=\(green.interimCallbacks) finals_before_stop=\(green.finalsBeforeStop) duplicate_final_callbacks=\(green.duplicateCallbacks)")
        #expect(green.effective == "deepgram" && green.connects == 1 && green.interimCallbacks == 0
                && green.finalsBeforeStop == 1 && green.duplicateCallbacks == 0)
    }

    @Test(.timeLimit(.minutes(1))) func lateFinalAfterStopReachesOneInsertion() async throws {
        let host = try await makeHost(stt: .deepgramStreaming)
        defer { host.tearDown() }
        var deliveries: [(String, DictationTimeline)] = []
        host.engine.onTranscript = { deliveries.append(($0, $1)) }
        try await startRecording(host)
        let socket = try await socket(host)
        socket.push(Frames.finalAlpha)
        try await wait("final alpha") { host.segments.count == 1 }
        host.engine.finish()
        try await wait("CloseStream") { socket.closeStreams == 1 }
        let closedAt = host.clock.elapsed
        host.clock.advance(by: .milliseconds(1000))
        let lateMs = Int((host.clock.elapsed - closedAt).components.seconds * 1000)
        socket.push(Frames.finalBeta)
        try await wait("late final") { host.segments.count == 2 }
        socket.push(Frames.metadata)   // terminal completion
        try await wait("insertion") { host.inserted.count == 1 && deliveries.count == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        print("ST1 GREEN late_final_ms=\(lateMs) final_segments=\(deliveries.first?.1.chunks ?? -1) insertion_calls=\(host.inserted.count)")
        #expect(lateMs == 1000 && deliveries.first?.1.chunks == 2 && host.inserted == ["alpha beta"])
        #expect(deliveries.first?.1.path == "deepgram-streaming" && host.http.transcriptions.value == 0)
    }

    @Test(.timeLimit(.minutes(1))) func terminalTimeoutRecoversOnceFromTheWholeRecording() async throws {
        let whole = "Recovered the whole recording of this dictation today."
        let host = try await makeHost(stt: .deepgramStreaming, transcript: whole)
        defer { host.tearDown() }
        try await startRecording(host)
        let socket = try await socket(host)
        socket.push(Frames.finalAlpha)
        try await wait("final alpha") { host.segments.count == 1 }
        host.engine.finish()
        try await wait("CloseStream") { socket.closeStreams == 1 && host.clock.sleepers >= 2 }
        let closedAt = host.clock.elapsed
        host.clock.advance(by: .milliseconds(1500))
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(host.http.transcriptions.value == 0 && host.inserted.isEmpty)   // still inside the 1.5 s wait
        host.clock.advance(by: .milliseconds(1))
        let timeoutMs = Int((host.clock.elapsed - closedAt).components.seconds * 1000
                            + (host.clock.elapsed - closedAt).components.attoseconds / 1_000_000_000_000_000)
        try await wait("whole-WAV insertion") { host.inserted.count == 1 }
        socket.push(Frames.finalBeta)   // a stale frame on the abandoned socket
        try await Task.sleep(nanoseconds: 30_000_000)
        let stale = host.segments.count - 1
        print("ST1 CONTROL terminal_timeout_ms=\(timeoutMs) groq_whole_wav_calls=\(host.http.transcriptions.value) stale_callbacks=\(stale) insertion_calls=\(host.inserted.count)")
        #expect(timeoutMs == 1501 && host.http.transcriptions.value == 1 && stale == 0 && host.inserted == [whole])
        #expect(host.http.completions.value == 1, "the recovered text passes cleanup exactly once")
        #expect(host.noteCount("stt_fallback=groq reason=terminal_timeout") == 1)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledSessionNeverInsertsAndTheNextSessionInsertsOnce() async throws {
        let host = try await makeHost(stt: .deepgramStreaming)
        defer { host.tearDown() }
        try await startRecording(host)
        let old = try await socket(host, 0)
        old.push(Frames.final("old", start: 0, duration: 0.5))
        try await wait("old final") { host.segments == ["old"] }
        host.engine.cancel()
        try await wait("old socket closed") { old.closedByClient }
        try await wait("idle") { !host.recorder.isAllocated || host.controller.micStartPending == false }
        try await startRecording(host)
        let fresh = try await socket(host, 1)
        fresh.push(Frames.final("new", start: 0, duration: 0.5))
        try await wait("new final") { host.segments == ["old", "new"] }
        old.push(Frames.final("stale", start: 0.5, duration: 0.5))
        host.engine.finish()
        try await wait("CloseStream") { fresh.closeStreams == 1 }
        fresh.serverClose()   // terminal completion by a normal close
        try await wait("insertion") { host.inserted.count == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        let oldInsertions = host.inserted.filter { $0.contains("old") || $0.contains("stale") }.count
        let newInsertions = host.inserted.filter { $0 == "new" }.count
        print("ST1 CONTROL cancel_then_new_session old_session_insertions=\(oldInsertions) new_session_insertions=\(newInsertions)")
        #expect(oldInsertions == 0 && newInsertions == 1 && host.inserted.count == 1)
        #expect(old.closeStreams == 0 && host.segments == ["old", "new"])
    }

    @Test(.timeLimit(.minutes(1))) func stopPhraseSplitAcrossFinalsEndsTheDictationOnce() async throws {
        let host = try await makeHost(stt: .deepgramStreaming)
        defer { host.tearDown() }
        try await startRecording(host)
        let socket = try await socket(host)
        socket.push(Frames.final("stop", start: 0, duration: 0.4))
        try await wait("stop") { host.segments.count == 1 }
        #expect(socket.closeStreams == 0 && host.noteCount("voice_stop=1 stage=live") == 0)
        socket.push(Frames.final("dictation", start: 0.4, duration: 0.4))
        try await wait("voice stop finishes the recording") { socket.closeStreams == 1 }
        socket.push(Frames.metadata)
        try await wait("outcome") { host.noteCount("voice_stop=1 stage=final") == 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        let list = host.segments.map { "\"\($0)\"" }.joined(separator: ",")
        print("ST1 CONTROL stop_phrase_segments=[\(list)] voice_stop_calls=\(host.noteCount("voice_stop=1 stage=live"))")
        #expect(host.segments == ["stop", "dictation"] && host.noteCount("voice_stop=1 stage=live") == 1)
        #expect(host.inserted.isEmpty, "the stop phrase itself is never pasted")
    }

    @Test(.timeLimit(.minutes(1))) func missingDeepgramKeyKeepsTheRecordingOnGroq() async throws {
        let groqText = "Groq kept this whole recording safe today."
        let host = try await makeHost(stt: .deepgramStreaming, transcript: groqText, reader: { service in
            guard service != DictationSTT.deepgramKeyService else { throw TranscriptionError.missingKey }
            return "fixture-key"
        })
        defer { host.tearDown() }
        try await startRecording(host)
        host.engine.finish()
        try await wait("Groq insertion") { host.inserted.count == 1 }
        let effective = host.controller.effectiveSTT == .groqChunked ? "groq" : "deepgram"
        let preserved = host.inserted == [groqText] ? 1 : 0
        print("ST1 CONTROL missing_key effective=\(effective) recording_preserved=\(preserved)")
        #expect(effective == "groq" && preserved == 1 && host.transport.connects == 0)
        #expect(host.noteCount("stt_fallback=groq reason=missing_key") == 1)
        #expect(host.http.transcriptions.value >= 1)
    }

    @Test(.timeLimit(.minutes(1))) func keychainServiceAndAccountAreDeepgramApiAndTheUserName() async throws {
        let fakeUser = "st1-fake-user"
        let calls = Box<[[String]]>([])
        let tool = KeychainToolReader(account: fakeUser, run: { _, arguments in
            calls.mutate { $0.append(arguments) }
            return KeychainToolReader.Output(status: 0, stdout: "dg-fixture-key\n")
        })
        let host = try await makeHost(stt: .deepgramStreaming, reader: { try tool.read(service: $0) })
        defer { host.tearDown() }
        try await startRecording(host)   // configureEngine + engineStart prefetch again: still one read
        _ = try await socket(host)
        let deepgramReads = calls.value.filter { $0.contains(DictationSTT.deepgramKeyService) }
        let account = deepgramReads.first.flatMap { args in args.firstIndex(of: "-a").map { args[$0 + 1] } } ?? "-"
        print("ST1 KEYCHAIN service=\(DictationSTT.deepgramKeyService) account=\(account) reads=\(deepgramReads.count)")
        #expect(deepgramReads.count == 1 && account == fakeUser)
        #expect(deepgramReads.first == ["find-generic-password", "-s", "deepgram-api", "-a", fakeUser, "-w"])
        #expect(host.transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Token dg-fixture-key")
        // Production default: the account is NSUserName() (no Keychain read happens here).
        #expect(KeychainToolReader().account == NSUserName())
    }
}
