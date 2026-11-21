import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

/// 1.29.17 (Archie 62.8.11, deep review row 9i3): M8 ordered finish flush, M6 Esc cancels the finishing dictation.
private final class DR3Panel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) { isOnScreen = true }
    func hide() { isOnScreen = false }
    func push(level: Double) {}
}
private final class DR3Apple: EngineAppleSession, @unchecked Sendable {
    private let lock = NSLock()
    private var cancels = 0
    var cancelled: Int { lock.withLock { cancels } }
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { "please send the report" }
    func cancel() { lock.withLock { cancels += 1 } }
}
/// STT (Groq or Scribe): every request answers 500 after `delayMs` while `failing`; counts requests sent.
private actor DR3HTTP: HTTPTransport {
    private(set) var sent = 0
    var failing = true
    let delayMs: UInt64
    init(delayMs: UInt64) { self.delayMs = delayMs }
    func heal() { failing = false }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isSTT = !request.url!.path.contains("chat")   // Groq transcriptions or a Scribe fallback
        sent += 1
        try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        let ok = !(isSTT && failing)
        let payload: [String: Any] = isSTT ? (ok ? ["text": "please send the report"] : ["error": ["message": "fixture"]]) :
            ["choices": [["finish_reason": "stop", "message": ["content": ""]]]]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 500, httpVersion: nil, headerFields: [:])!)
    }
}

@Suite("DR3FinishFlushEsc", .serialized) @MainActor
struct DR3FinishFlushEscTests {
    private static func tone(_ count: Int) -> [Float] {
        (0..<count).map { Float(0.25 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
    }

    /// M8 (A2-A6): chunks admitted before stop() but not yet drained reach the old session, in order, once each.
    @Test func stopFlushesAdmittedChunksInOrder() throws {
        let frames = Self.tone(2_400 * 5 + 1_200)
        func run(drainEach: Bool) throws -> [Int16] {
            let (recorder, _, _, _) = V61CaptureLifetimeTests.makeRecorder(name: "dr3m8", kind: .dictation)
            recorder.retainsCapturedSamples = false
            let lock = NSLock()
            var got: [Int16] = []
            recorder.onPCMChunk = { pcm in lock.withLock { got += pcm } }
            try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
            for (k, start) in stride(from: 0, to: frames.count, by: 2_400).enumerated() {
                _ = recorder.offlineInputFrames(Array(frames[start..<min(start + 2_400, frames.count)]), at: Double(k + 1) * 0.1)
                if drainEach { recorder.offlineDrainPCM() }
            }
            _ = recorder.stop()                   // the finish tap lands before the delivery queue drained
            recorder.offlineDrainPCM()
            return lock.withLock { got }
        }
        let reference = try run(drainEach: true)
        let raced = try run(drainEach: false)
        let same = raced == reference
        print("DR3 M8 \(same ? "GREEN" : "RED") finish_flush delivered=\(raced.count) reference=\(reference.count) in_order=\(same ? 1 : 0)")
        #expect(reference.count >= 2_400 * 5)
        #expect(same)
    }

    /// M8 control: a restart after stop() gets none of the old dictation's samples.
    @Test func restartAfterStopGetsNoOldSamples() throws {
        let (recorder, _, _, _) = V61CaptureLifetimeTests.makeRecorder(name: "dr3m8r", kind: .dictation)
        recorder.retainsCapturedSamples = false
        let lock = NSLock()
        var old = 0, fresh: [Int16] = []
        recorder.onPCMChunk = { pcm in lock.withLock { old += pcm.count } }
        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        _ = recorder.offlineInputFrames(Self.tone(2_400 * 3), at: 0.1)
        _ = recorder.stop()
        recorder.onPCMChunk = { pcm in lock.withLock { fresh += pcm } }
        try recorder.offlineStartInput(at: 1.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        recorder.offlineDrainPCM()
        let leaked = lock.withLock { fresh.count }
        print("DR3 M8 CONTROL restart_old_samples=\(leaked) old_delivered=\(lock.withLock { old })")
        #expect(leaked == 0)
        _ = recorder.stop()
    }

    /// M6 (A2-A9): Esc while the finished dictation is transcribing cancels that dictation's sessions:
    /// no further STT request, the Apple session cancelled; a new dictation then succeeds.
    @Test func escDuringTranscriptionCancelsTheFinishingSessions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-dr3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        let pcm = (0..<72_000).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
        try WAVEncoder.encode(samples: pcm, sampleRate: 24_000, channels: 1).write(to: url)
        let paths = AppPaths(home: dir.appendingPathComponent("home"))
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-dr3-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05)
        recorder.manualPacing = true
        recorder.note = { _ in }
        let stt = DR3HTTP(delayMs: 300)
        let apples = NSMutableArray()
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { let a = DR3Apple(); apples.add(a); return a },
            sttTransport: stt, groqCleanupTransport: DR3HTTP(delayMs: 0), localCleanupTransport: DR3HTTP(delayMs: 0),
            inserter: TextInserter(pasteboard: clipboard, postKeystroke: {}),
            panelFactory: { DR3Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .captureOnly, dependencies: dependencies)
        let engine = DictationEngine(controller: controller)
        var states: [DictateAppKit.DictationState] = []
        engine.onState = { states.append($0) }
        engine.start()
        try await drive(recorder, ticks: 12)
        engine.finish()
        try await waitFor { states.contains(.transcribing) }
        try await waitForAsync { await stt.sent >= 1 }
        engine.cancel()                                         // Esc while the first request is in flight
        let atEsc = await stt.sent
        try await Task.sleep(nanoseconds: 1_500_000_000)        // past the first answer + the bounded retry
        let afterEsc = await stt.sent - atEsc
        let firstApple = apples.firstObject as? DR3Apple
        let appleCancelled = firstApple?.cancelled ?? -1
        print("DR3 M6 \(afterEsc == 0 && appleCancelled > 0 ? "GREEN" : "RED") esc_after_finish requests_after_esc=\(afterEsc) apple_cancelled=\(appleCancelled)")
        #expect(afterEsc == 0)
        #expect(appleCancelled > 0)
        // A new dictation on a healthy transport still finishes (one non-cancel outcome logged).
        await stt.heal()
        engine.start()
        try await drive(recorder, ticks: 12)
        engine.finish()
        try await waitFor { (try? String(contentsOf: paths.logURL, encoding: .utf8).split(separator: "\n").count) == 2 }
        let log = try String(contentsOf: paths.logURL, encoding: .utf8).split(separator: "\n")
        print("DR3 M6 CONTROL new_session_outcome=\(log.last.map { $0.contains("outcome=cancel") ? "cancel" : "finished" } ?? "none")")
        #expect(log.first?.contains("outcome=cancel") == true && log.last?.contains("outcome=cancel") == false)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out")
        throw URLError(.timedOut)
    }
    private func waitForAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out")
        throw URLError(.timedOut)
    }
    private func drive(_ recorder: WAVInjectedRecorder, ticks: Int) async throws {
        var stepped = 0
        let deadline = ContinuousClock.now + .seconds(10)
        while stepped < ticks && ContinuousClock.now < deadline {
            if recorder.isRunning { recorder.step(); stepped += 1 }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
