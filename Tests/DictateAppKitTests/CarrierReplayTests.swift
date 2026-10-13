import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

private final class Panel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) { isOnScreen = true }
    func hide() { isOnScreen = false }
    func push(level: Double) {}
}
private final class Apple: EngineAppleSession, @unchecked Sendable {
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { "please send the report" }
    func cancel() {}
}
private actor HTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let payload: [String: Any] = request.url!.path.contains("transcriptions") ? ["text": "please send the report"] :
            ["choices": [["finish_reason": "stop", "message": ["content": ""]]]]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}
private final class Lines: @unchecked Sendable {
    let lock = NSLock()
    var all: [String] = []
    func add(_ line: String) { lock.withLock { all.append(line) } }
    var snapshot: [String] { lock.withLock { all } }
}

/// v1.11 L4: R4 (10-13 07:07:09, 41f98dbd) replayed through the production CaptureFeed
/// (`headset_takeover`) and, for the session-end line, the production controller. No hardware,
/// no network. RED on v1.10: `headset_takeover` does not exist there; its equivalent readings were
/// `bridge_src=builtin` and `headset_restart=1 result=still_silent` (CarrierTelemetryTests).
@Suite("CarrierReplay")
struct CarrierReplayTests {
    private static func tone(seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
    }
    private func wav(seconds: Double) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-carrier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try WAVEncoder.encode(samples: Self.tone(seconds: seconds), sampleRate: 24_000, channels: 1).write(to: url)
        return (dir, url)
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

    @Test func takeoverRecorderReportsTheHeadsetCarrier() async throws {
        let (dir, url) = try wav(seconds: 3.5)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: .headsetTakeover)
        let notes = Lines()
        let lock = NSLock()
        var pcm: [Int16] = []
        recorder.note = { notes.add($0) }
        recorder.mediaLimit = 3.2
        recorder.onPCMChunk = { chunk in lock.withLock { pcm += chunk } }
        try recorder.start()
        recorder.resetCapture()
        let deadline = ContinuousClock.now + .seconds(10)
        while lock.withLock({ pcm.count }) < 3 * 24_000, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = recorder.stop()
        let stats = recorder.stats
        #expect(stats.bridgeSource == "builtin")                                    // the legacy field: the bridge
        #expect(stats.carrier == "builtin:0-1100,headset:1100-\(stats.recordingMs)")
        #expect(stats.headsetCarriedMs == stats.recordingMs - 1_100 && stats.headsetCarriedMs > 1_800)
        #expect(stats.headsetRestart == "skipped")
        #expect(notes.snapshot.contains("bt_recovery=coalesced path=restart"))
        let got = lock.withLock { pcm }
        #expect(Array(got.prefix(3 * 24_000)) == Array(Self.tone(seconds: 3.5).prefix(3 * 24_000)))   // no loss or duplicate at the takeover
    }

    @MainActor @Test func takeoverSessionEndLineNamesKindAndCarrier() async throws {
        let (dir, url) = try wav(seconds: 3.5)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppPaths(home: dir.appendingPathComponent("home"))
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-carrier-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: .headsetTakeover)
        let notes = Lines()
        recorder.note = { notes.add($0) }
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { Apple() },
            sttTransport: HTTP(), groqCleanupTransport: HTTP(), localCleanupTransport: HTTP(),
            inserter: TextInserter(pasteboard: clipboard, postKeystroke: {}),
            panelFactory: { Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .captureOnly,
                                       dependencies: dependencies)
        controller.onSessionNote = { notes.add($0) }
        let engine = DictationEngine(controller: controller)
        var levels = 0
        engine.onState = { if case .recording = $0 { levels += 1 } }
        engine.start()
        try await waitFor { levels >= 25 }                                          // ≥ 2.4 s of media
        engine.finish()
        try await waitFor { notes.snapshot.contains { $0.contains("event=end") } }
        let end = notes.snapshot.first { $0.contains("event=end") } ?? ""
        #expect(end.contains(" event=end outcome=ok ") && end.contains(" kind=dictation recording_ms="))
        #expect(end.contains(" carrier=builtin:0-1100,headset:1100-"))
        let carried = Int(end.components(separatedBy: "headset_carried_ms=").last?.components(separatedBy: " ").first ?? "") ?? 0
        #expect(carried > 1_000)
        #expect(!end.contains("capture_intervals_truncated"))
        #expect(!notes.snapshot.contains { $0.contains("still_silent") })
    }
}
