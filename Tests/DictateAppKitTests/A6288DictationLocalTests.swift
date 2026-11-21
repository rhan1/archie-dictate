import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

private final class A6288Panel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) {}
    func hide() {}
    func push(level: Double) {}
}

private final class A6288Apple: EngineAppleSession, @unchecked Sendable {
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { "Testing the fixture." }
    func cancel() {}
}

/// Counts speech-to-text requests to the cloud (cleanup requests are not STT); answers like Groq.
private actor A6288CloudHTTP: HTTPTransport {
    private(set) var groq = 0
    private(set) var scribe = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url == ScribeClient.endpoint { scribe += 1 }
        if request.url == TranscriptionClient.groqEndpoint { groq += 1 }
        return (try JSONSerialization.data(withJSONObject: ["text": "Testing the fixture."]),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct A6288Local: LocalChunkSTT {
    var modelID: String { "fake-local" }
    func transcribe(pcm16k: [Int16]) async throws -> String { "Testing the fixture." }
}

/// archie-6288: ⌥⌥ dictation with a host's on-device engine — every chunk is answered on the Mac, no cloud STT
/// request is made, and the end line carries `stt_local=`. Host facade + WAV recorder, no capture device, no network.
@Suite("A6288DictationLocalTests") @MainActor
struct A6288DictationLocalTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("Timed out waiting for offline injected engine")
        throw URLError(.timedOut)
    }

    @Test func dictation_routes_to_local_when_on() async throws {
        let injected = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-a6288-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root.appendingPathComponent("home"))
        let wav = root.appendingPathComponent("fixture.wav")
        let tone = (0..<24_000).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
        let samples = [Int16](repeating: 0, count: 4_800) + tone + [Int16](repeating: 0, count: 96_000)
        try WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1).write(to: wav)
        let wave = WAVInjectedRecorder(url: wav, scenario: .plain)
        wave.manualPacing = true
        wave.note = { _ in }
        // Both units have no frame callbacks. Injection must not start either one; the real
        // recorder control exercises its normal health/recovery machinery on those same fakes.
        let hardwareLog = CaptureLeaseRecorderTests.Log()
        let (hardware, builtin, _) = CaptureLeaseRecorderTests.recorder("dead", hardwareLog, broker: CaptureLeaseBroker())
        let recorder: EngineRecorder = wave
        _ = hardware
        let keys = KeyStore(reader: { _ in "fixture-key" })
        keys.prefetch(services: ["groq-api", "elevenlabs-api"])
        try await waitFor { keys.key(for: "groq-api") != nil && keys.key(for: "elevenlabs-api") != nil }
        let pb = NSPasteboard(name: .init("dictate-a6288-local-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let http = A6288CloudHTTP()
        var pastes = 0
        let deps = EngineDependencies(recorder: recorder, makeApple: { A6288Apple() },
            sttTransport: http, groqCleanupTransport: http, localCleanupTransport: http,
            inserter: TextInserter(pasteboard: pb, postKeystroke: { pastes += 1 }, axReader: { [] }),
            panelFactory: { A6288Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.fixture") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate,
                                       dependencies: deps, injectedAudioURL: injected ? wav : nil)
        let engine = DictationEngine(controller: controller)
        engine.localSTT { A6288Local() }
        var timelines: [String] = []
        engine.onDiagnostic = { if $0.contains("timeline:") { timelines.append($0) } }
        controller.configureEngine()
        defer { engine.cancel() }
        var ends: [String] = []
        var started = false
        controller.onSessionNote = {
            if $0.contains("event=start") { started = true }
            if $0.contains("event=end") { ends.append($0) }
        }
        let rig = root.appendingPathComponent("rig")
        try FileManager.default.createDirectory(at: rig, withIntermediateDirectories: true)
        #expect(engine.enableRig(launchEnvironment: ["DICTATE_RIG": "1", "DICTATE_RIG_DIR": rig.path]) {
            engine.handle($0 == .tap ? .tap : .doubleTap)
        })
        let trigger = rig.appendingPathComponent("trigger")
        #expect(FileManager.default.createFile(atPath: trigger.path, contents: Data("chord selftest\n".utf8),
                                               attributes: [.posixPermissions: 0o600]))
        try await waitFor { recorder.isRunning && started && !controller.micStartPending }
        if injected {
            for _ in 0..<90 {
                wave.step()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            // A dead-health RED must surface its actual outcome before checking output text.
            if ends.isEmpty {
                #expect(FileManager.default.createFile(atPath: trigger.path, contents: Data("chord selftest\n".utf8),
                                                       attributes: [.posixPermissions: 0o600]))
            }
        }
        try await waitFor { !ends.isEmpty }
        let outcome = ends.first!.split(separator: " ").first { $0.hasPrefix("outcome=") }.map(String.init) ?? "outcome=missing"
        print("SELFTEST_ENGINE injected=\(injected ? 1 : 0) \(outcome)")
        let output = rig.appendingPathComponent("out/selftest.txt")
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let groq = await http.groq, scribe = await http.scribe
        try await waitFor { !timelines.isEmpty }
        let local = timelines.first!.split(separator: " ").first { $0.hasPrefix("stt_local=") }.map(String.init) ?? "stt_local=missing"
        let ok = outcome == "outcome=ok" && text == "Testing the fixture." && groq == 0 && scribe == 0 && local != "stt_local=0"
            && local != "stt_local=missing"
        print("P \(ok ? "GREEN" : "RED") dictation_routes_to_local=\(ok ? 1 : 0) \(outcome) \(local) groq_stt_requests=\(groq) scribe_requests=\(scribe)")
        #expect(ok)
        #expect(hardwareLog.all.isEmpty && builtin.epochs.isEmpty)
    }
}
