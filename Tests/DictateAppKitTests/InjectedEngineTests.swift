import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

private final class InjectedPanel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) {}
    func hide() {}
    func push(level: Double) {}
}

private final class InjectedApple: EngineAppleSession, @unchecked Sendable {
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { "Testing the fixture." }
    func cancel() {}
}

private actor InjectedHTTP: HTTPTransport {
    private(set) var calls = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        let payload: [String: Any] = request.url!.path.contains("transcriptions")
            ? ["text": "Testing the fixture."]
            : ["choices": [["finish_reason": "stop", "message": ["content": "Testing the fixture."]]]]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// The host facade, real rig watcher/sink and WAV recorder, with no physical capture or network.
@Suite("InjectedEngineTests") @MainActor
struct InjectedEngineTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("Timed out waiting for offline injected engine")
        throw URLError(.timedOut)
    }

    @Test func injectedChordWritesTextDespiteSilentTailAndNoHardwareCallbacks() async throws {
        try await run(injected: true)
    }

    @Test func nonInjectedDeadHardwareStillFailsMicDead() async throws {
        try await run(injected: false)
    }

    private func run(injected: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-injected-engine-\(UUID().uuidString)")
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
        let recorder: EngineRecorder = injected ? wave : hardware
        let keys = KeyStore(reader: { _ in "fixture-key" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let pb = NSPasteboard(name: .init("dictate-injected-engine-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let http = InjectedHTTP()
        var pastes = 0
        let deps = EngineDependencies(recorder: recorder, makeApple: { InjectedApple() },
            sttTransport: http, groqCleanupTransport: http, localCleanupTransport: http,
            inserter: TextInserter(pasteboard: pb, postKeystroke: { pastes += 1 }, axReader: { [] }),
            panelFactory: { InjectedPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.fixture") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate,
                                       dependencies: deps, injectedAudioURL: injected ? wav : nil)
        let engine = DictationEngine(controller: controller)
        defer { engine.cancel() }
        var ends: [String] = []
        controller.onSessionNote = { if $0.contains("event=end") { ends.append($0) } }
        let rig = root.appendingPathComponent("rig")
        try FileManager.default.createDirectory(at: rig, withIntermediateDirectories: true)
        #expect(engine.enableRig(launchEnvironment: ["DICTATE_RIG": "1", "DICTATE_RIG_DIR": rig.path]) {
            engine.handle($0 == .tap ? .tap : .doubleTap)
        })
        let trigger = rig.appendingPathComponent("trigger")
        try Data("chord selftest\n".utf8).write(to: trigger)
        try await waitFor { recorder.isRunning }
        if injected {
            for _ in 0..<90 {
                wave.step()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            // A dead-health RED must surface its actual outcome before checking output text.
            if ends.isEmpty { try Data("tap selftest\n".utf8).write(to: trigger) }
        }
        try await waitFor { !ends.isEmpty }
        let outcome = ends.first!.split(separator: " ").first { $0.hasPrefix("outcome=") }.map(String.init) ?? "outcome=missing"
        print("SELFTEST_ENGINE injected=\(injected ? 1 : 0) \(outcome)")
        let output = rig.appendingPathComponent("out/selftest.txt")
        if injected {
            #expect(outcome == "outcome=ok")
            #expect((try? String(contentsOf: output, encoding: .utf8)) == "Testing the fixture.")
            #expect(hardwareLog.all.isEmpty && builtin.epochs.isEmpty)
        } else {
            #expect(outcome == "outcome=error:mic_dead")
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(await http.calls == 0)
            #expect(!hardwareLog.all.isEmpty)
        }
        #expect(pastes == 0)
    }
}
