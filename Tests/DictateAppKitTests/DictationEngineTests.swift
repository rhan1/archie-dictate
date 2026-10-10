import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

private final class TestPanel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    var shows = 0, hides = 0, levels = 0
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) { shows += 1; isOnScreen = true }
    func hide() { hides += 1; isOnScreen = false }
    func push(level: Double) { levels += 1 }
}

private final class TestRecorder: EngineRecorder {
    var isRunning = false
    var onLevel: ((Double) -> Void)?
    var onPCMChunk: (([Int16]) -> Void)?
    var onFirstBuffer: (() -> Void)?
    var onCaptureFailure: (() -> Void)?
    var stats = AudioRecorder.CaptureStats()
    var ready = false
    var starts = 0, stops = 0
    func start(device: MicChoice) throws { starts += 1; isRunning = true; onFirstBuffer?() }
    func startAsync(device: MicChoice) async throws { try start(device: device) }
    func rebuild() throws {}
    func rebuildAsync() async throws {}
    func resetCapture() { ready = true }
    func stop() -> [Float] {
        stops += 1; isRunning = false
        onPCMChunk?([Int16](repeating: 1000, count: 9600))
        return [Float](repeating: 0.1, count: 9600)
    }
}
private final class TestApple: EngineAppleSession, @unchecked Sendable {
    let text: String
    private let lock = NSLock()
    private var finished = 0
    init(_ text: String) { self.text = text }
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { lock.withLock { finished += 1 }; return text }
    func cancel() {}
    var finishes: Int { lock.withLock { finished } }
}
private actor TestHTTP: HTTPTransport {
    let text: String
    private(set) var requests: [URLRequest] = []
    init(_ text: String) { self.text = text }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let payload: [String: Any] = request.url!.path.contains("transcriptions") ? ["text": text] :
            ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
        return (try JSONSerialization.data(withJSONObject: payload), HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["x-ratelimit-remaining-requests": "42"])!)
    }
}

@Suite("DictationEngineTests") @MainActor
struct DictationEngineTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for fake pipeline")
        throw URLError(.timedOut)
    }

    @Test func outcomeWordsMatchPill() {
        let cases: [(PillOutcome.Kind, String)] = [(.error("mic_denied"), "no mic"), (.error("mic_start"), "no mic"),
            (.error("missing_key"), "no key"), (.error("network_-1009"), "offline"), (.error("network_timedOut"), "timeout"),
            (.held("focus_changed"), "held"), (.held("no_stt"), "no speech"), (.error("silence"), "no speech"),
            (.rawPasted("rejected:ratio"), "raw"), (.error("decode"), "error")]
        for (kind, word) in cases {
            #expect(DictateAppKit.DictationState.outcome(kind) == .error(word: word))
            #expect(PillOutcome(kind).label == word)
        }
        #expect(DictateAppKit.DictationState.outcome(.held("focus_changed"), text: "preview") == .held(preview: "preview"))
        #expect(DictateAppKit.DictationState.outcome(.ok) == .pasted)
    }

    @Test func noSurfaceSkipsEveryPanelOperationWithPositiveControl() {
        let panel = TestPanel()
        var creations = 0
        let gate = EnginePanel(surface: .none, factory: { creations += 1; return panel })
        var modes: [PillPanel.Mode] = []
        gate.onMode = { modes.append($0) }
        gate.show(.warming); gate.show(.recording); gate.push(level: 0.5); gate.show(.transcribing)
        gate.show(.error, held: true, status: "held"); gate.hide()
        #expect(creations == 0 && panel.shows == 0 && panel.hides == 0 && panel.levels == 0)
        #expect(modes == [.warming, .recording, .transcribing, .error, .hidden])
        #expect(!gate.isOnScreen && gate.frame == .zero)
        gate.surface = .pill
        gate.show(.recording); gate.push(level: 0.5); gate.hide()
        #expect(creations == 1 && panel.shows == 1 && panel.hides == 1 && panel.levels == 1)
    }

    @Test func facadeOutcomesAndRecoveryRemainActiveWithNoSurface() {
        let controller = AppController(keyStore: KeyStore(reader: { _ in "fixture" }),
            paths: AppPaths(home: URL(fileURLWithPath: "/unused")), surface: .none, mode: .dictate)
        let engine = DictationEngine(controller: controller)
        controller.configureEngine()
        var states: [DictateAppKit.DictationState] = []
        engine.onState = { states.append($0) }
        controller.showOutcome(.held("focus_changed"), text: "preview")
        #expect(states.last == .held(preview: "preview"))
        engine.escape()
        #expect(states.last == .idle)
        controller.showOutcome(.error("missing_key"))
        #expect(states.last == .error(word: "no key"))
        engine.cancel()
        #expect(states.last == .idle)
    }

    @Test func captureOnlyAndQuotaRunThroughFacadeWithFakes() async throws {
        // Three positive controls: ordinary Groq+cleanup+paste; Groq capture-only;
        // quota Apple+local+paste. Every HTTP/insertion counter is exercised.
        for (mode, quota) in [(DictationEngine.Mode.dictate, false), (.captureOnly, false), (.dictate, true)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-l1-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = AppPaths(home: root)
            let keys = KeyStore(reader: { _ in "fixture" })
            keys.prefetch(services: ["groq-api"])
            try await waitFor { keys.key(for: "groq-api") != nil }
            let raw = "please send the whole report on Tuesday"
            let clean = "Please send the whole report on Tuesday."
            let recorder = TestRecorder()
            let apple = TestApple(raw)
            let stt = TestHTTP(raw), groq = TestHTTP(clean), local = TestHTTP(clean)
            let panel = TestPanel()
            var creations = 0, pastes = 0
            let clipboard = NSPasteboard(name: .init("dictate-l1-\(UUID().uuidString)"))
            defer { clipboard.releaseGlobally() }
            clipboard.setString("ORIGINAL", forType: .string)
            let inserter = TextInserter(pasteboard: clipboard, postKeystroke: { pastes += 1 })
            let dependencies = EngineDependencies(recorder: recorder, makeApple: { apple }, sttTransport: stt,
                groqCleanupTransport: groq, localCleanupTransport: local, inserter: inserter,
                panelFactory: { creations += 1; return panel }, requestMicrophoneAccess: { $0(true) },
                frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
            let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: mode, dependencies: dependencies)
            let engine = DictationEngine(controller: controller)
            engine.forceFallback = quota ? .quota : nil
            var states: [DictateAppKit.DictationState] = []
            var deliveries: [(String, DictationTimeline)] = []
            var limits: [GroqRateLimit] = []
            engine.onState = { states.append($0) }
            engine.onTranscript = { deliveries.append(($0, $1)) }
            engine.onGroqRateLimit = { limits.append($0) }
            engine.start()
            try await waitFor { recorder.ready }
            recorder.onLevel?(2); recorder.onLevel?(-1)
            #expect(states.contains(.warming) && states.contains(.recording(level: 0)))
            #expect(states.contains(.recording(level: 1)))
            engine.finish()
            engine.finish() // No duplicate completion/request while transcribing.
            try await waitFor { !deliveries.isEmpty }
            try await waitFor { FileManager.default.fileExists(atPath: paths.logURL.path) }
            #expect(deliveries.count == 1)
            #expect(deliveries[0].0 == (mode == .captureOnly ? raw : clean))
            #expect(states.contains(.transcribing))
            #expect(await stt.requests.count == (quota ? 0 : 1))
            #expect(await local.requests.count == (quota ? 1 : 0))
            #expect(apple.finishes == 1)
            if mode == .captureOnly {
                #expect(await groq.requests.isEmpty)
                #expect(pastes == 0 && clipboard.string(forType: .string) == "ORIGINAL")
                #expect(states.last == .idle && !states.contains(.pasted))
                #expect(deliveries[0].1.cleanup_ms == nil && deliveries[0].1.cleanup_mode == "none")
            } else {
                try await waitFor { pastes == 1 }
                #expect(states.last == .pasted)
                #expect(await groq.requests.isEmpty == quota)
                try await waitFor { clipboard.string(forType: .string) == "ORIGINAL" }
            }
            #expect(creations == 0 && panel.shows == 0 && panel.hides == 0 && panel.levels == 0)
            #expect(deliveries[0].1.path == (quota ? "apple" : "groq-chunked"))
            #expect(deliveries[0].1.fallback == (quota ? "quota" : nil))
            let line = try String(contentsOf: paths.logURL, encoding: .utf8)
            #expect(line.contains("fallback=quota") == quota)
            #expect(!line.contains(raw) && !line.contains(clean))
            if quota { #expect(limits.isEmpty) }
            else {
                try await waitFor { limits.contains { $0.endpoint == .stt } }
                #expect(limits.first { $0.endpoint == .stt }?.remainingRequests == 42)
                #expect(limits.contains { $0.endpoint == .cleanup } == (mode == .dictate))
            }
        }
    }
}
