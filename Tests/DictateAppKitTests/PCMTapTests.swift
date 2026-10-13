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
private final class Samples: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Int16] = []
    private var chunks = 0
    func add(_ chunk: [Int16]) { lock.withLock { all += chunk; chunks += 1 } }
    var snapshot: [Int16] { lock.withLock { all } }
    var count: Int { lock.withLock { chunks } }
}
/// The transcriber's view of the same stream (what `engine.append(pcm)` received).
private final class RecordingApple: EngineAppleSession, @unchecked Sendable {
    let received = Samples()
    func start() async throws {}
    func append(_ samples: [Int16]) { received.add(samples) }
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

/// v1.12.1 (L7): the host's read-only PCM tap, end to end on the production controller with the WAV
/// hatch. No hardware, no network.
@Suite("PCMTap") @MainActor
struct PCMTapTests {
    /// Every sample distinct from its neighbours: a lost, repeated or reordered chunk shows.
    private static func ramp(seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { Int16(truncatingIfNeeded: ($0 * 7) % 30_011 - 15_000) }
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

    @Test func everyInjectedSampleReachesTheTapExactlyOnceInOrder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-pcmtap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = Self.ramp(seconds: 3.0)
        let url = dir.appendingPathComponent("ramp.wav")
        try WAVEncoder.encode(samples: clip, sampleRate: 24_000, channels: 1).write(to: url)
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-pcmtap-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05)
        recorder.note = { _ in }
        recorder.mediaLimit = 2.5                                   // inside the clip: every sample is the ramp's
        let apple = RecordingApple()
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { apple },
            sttTransport: HTTP(), groqCleanupTransport: HTTP(), localCleanupTransport: HTTP(),
            inserter: TextInserter(pasteboard: clipboard, postKeystroke: {}),
            panelFactory: { Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: AppPaths(home: dir.appendingPathComponent("home")),
                                       surface: .none, mode: .captureOnly, dependencies: dependencies)
        var ended = false
        controller.onSessionNote = { if $0.contains("event=end") { ended = true } }
        let engine = DictationEngine(controller: controller)
        let tapped = Samples()
        engine.onPCMTap = { tapped.add($0) }
        engine.start()
        try await waitFor { apple.received.snapshot.count >= Int(2.4 * 24_000) }
        engine.finish()
        try await waitFor { ended }
        controller.pcmTap.drain()
        let got = tapped.snapshot
        #expect(got.count >= Int(2.4 * 24_000))
        #expect(got == apple.received.snapshot)                     // the same chunks the transcriber received …
        #expect(tapped.count == apple.received.count)
        #expect(got == Array(clip.prefix(got.count)))               // … every injected sample once, in order
    }
}
