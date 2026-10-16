import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

private final class RigPanel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) { isOnScreen = true }
    func hide() { isOnScreen = false }
    func push(level: Double) {}
}

private final class RigRecorder: EngineRecorder {
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
    func stop() -> [Float] {
        isRunning = false
        onPCMChunk?([Int16](repeating: 1000, count: 9600))
        return [Float](repeating: 0.1, count: 9600)
    }
}

private final class RigApple: EngineAppleSession, @unchecked Sendable {
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { "" }
    func cancel() {}
}

private actor RigHTTP: HTTPTransport {
    let text: String
    init(_ text: String) { self.text = text }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let payload: [String: Any] = request.url!.path.contains("transcriptions") ? ["text": text] :
            ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// v1.14 L2: the rig hooks are compiled into every build but do nothing unless the host's launch
/// environment carried DICTATE_RIG=1 (+ DICTATE_RIG_DIR). Both runs drive one whole dictation through
/// the production controller with fakes: no mic, no device, no network, no keystroke.
@Suite("RigInertTests") @MainActor
struct RigInertTests {
    private func waitFor(_ condition: () -> Bool, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("Timed out", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }

    private struct Run {
        var enabled = false
        var gestures: [RigGesture] = []
        var pastes = 0
        var endLine = ""
        var triggerLeft = false
        var sinkText: String?
    }

    /// One dictation. The test writes the rig's trigger file twice (start, finish) as live-rig.zsh does;
    /// when the rig is off nothing reads it, so the test then performs ⌥⌥ through the hotkey path itself.
    private func dictate(environment: (URL) -> [String: String]) async throws -> Run {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-rig-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let rigDir = root.appendingPathComponent("rig", isDirectory: true)
        try FileManager.default.createDirectory(at: rigDir, withIntermediateDirectories: true)
        let paths = AppPaths(home: root.appendingPathComponent("home"))
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-rig-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        var run = Run()
        let recorder = RigRecorder()
        let text = "Please send the whole report on Tuesday."
        var axTexts: [String]? = []
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { RigApple() }, sttTransport: RigHTTP(text),
            groqCleanupTransport: RigHTTP(text), localCleanupTransport: RigHTTP(text),
            inserter: TextInserter(pasteboard: clipboard, postKeystroke: { run.pastes += 1; axTexts = [text] },
                                   axReader: { axTexts }),
            panelFactory: { RigPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate, dependencies: dependencies)
        let engine = DictationEngine(controller: controller)
        var ends: [String] = []
        controller.onSessionNote = { if $0.contains("event=end") { ends.append($0) } }
        run.enabled = engine.enableRig(launchEnvironment: environment(rigDir)) { gesture in
            run.gestures.append(gesture)
            engine.handle(gesture == .tap ? .tap : .doubleTap)
        }
        let trigger = rigDir.appendingPathComponent("trigger")
        func chord() async throws {
            FileManager.default.createFile(atPath: trigger.path, contents: Data("chord R1\n".utf8), attributes: [.posixPermissions: 0o600])
            let before = run.gestures.count
            if run.enabled {
                try await waitFor { run.gestures.count == before + 2 }
            } else {
                try await Task.sleep(nanoseconds: 300_000_000)            // six watcher polls, were there a watcher
                run.triggerLeft = FileManager.default.fileExists(atPath: trigger.path)
                try FileManager.default.removeItem(at: trigger)
                engine.handle(.tap)
                engine.handle(.doubleTap)
            }
        }
        try await chord()
        try await waitFor { recorder.starts > 0 && !controller.micStartPending }
        try await chord()
        try await waitFor { !ends.isEmpty }
        try await waitFor { FileManager.default.fileExists(atPath: paths.logURL.path) }
        run.endLine = ends.first ?? ""
        run.sinkText = try? String(contentsOf: rigDir.appendingPathComponent("out/R1.txt"), encoding: .utf8)
        return run
    }

    /// RED for the hook: without DICTATE_RIG=1 at launch the trigger is never read, the paste goes to the
    /// frontmost app as always, no file is written and the session line carries no rig marker.
    @Test func rigHooksAreInertWithoutTheLaunchVariable() async throws {
        for env in [{ (_: URL) in [String: String]() },
                    { (dir: URL) in ["DICTATE_RIG_DIR": dir.path] },
                    { (dir: URL) in ["DICTATE_RIG": "0", "DICTATE_RIG_DIR": dir.path] }] {
            let run = try await dictate(environment: env)
            #expect(!run.enabled)
            #expect(run.gestures.isEmpty)
            #expect(run.triggerLeft)                                       // nobody consumed it
            #expect(run.pastes == 1)
            #expect(run.sinkText == nil)
            #expect(run.endLine.contains("outcome=ok"))
            #expect(!run.endLine.contains("rig="))
        }
    }

    /// GREEN (positive control): with DICTATE_RIG=1 the same trigger file performs ⌥⌥ twice (start,
    /// finish), the text lands in out/R1.txt, nothing is pasted, and the session line says rig=1.
    @Test func rigHooksDriveADictationWhenLaunchedWithTheVariable() async throws {
        let run = try await dictate { dir in ["DICTATE_RIG": "1", "DICTATE_RIG_DIR": dir.path] }
        #expect(run.enabled)
        #expect(run.gestures == [.tap, .doubleTap, .tap, .doubleTap])
        #expect(run.pastes == 0)
        #expect(run.sinkText == "Please send the whole report on Tuesday.")
        #expect(run.endLine.contains("outcome=ok"))
        #expect(run.endLine.hasSuffix(" rig=1 rig_row=R1"))
    }
}
