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
    var onCaptureFailure: ((CaptureFailure) -> Void)?
    var stats = AudioRecorder.CaptureStats()
    var ready = false
    var starts = 0, stops = 0
    var isAllocated = false
    var bridgeHasAudio = false
    func release() { isAllocated = false; isRunning = false }
    func start(device: MicChoice) throws { starts += 1; isAllocated = true; isRunning = true; onFirstBuffer?() }
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
    // Wall-clock deadline: under suite load 2000 × 1 ms polls ran out before the fake pipeline finished.
    private func waitFor(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for fake pipeline", sourceLocation: sourceLocation)
        throw URLError(.timedOut)
    }

    /// v1.7 H1 end-to-end on the production controller: the injected WAV is the built-in mic
    /// and the headset delivers only digital zeros. Network: Groq whisper only (capture-only =
    /// no cleanup, no paste); fakes for panel, Apple, pasteboard, permission; media untouched.
    /// Skipped unless DICTATE_E2E_WAV (24 kHz mono 16-bit speech of ShadowScore.script) and
    /// GROQ_API_KEY are set. DICTATE_E2E_SCENARIO=plain runs the same WAV without the headset.
    /// Prints counts only, never the transcript.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DICTATE_E2E_WAV"] != nil))
    func e2eHeadsetZerosBuiltinSpeech() async throws {
        let env = ProcessInfo.processInfo.environment
        let wav = URL(fileURLWithPath: env["DICTATE_E2E_WAV"] ?? "")
        let key = try #require(env["GROQ_API_KEY"])
        let scenario = WAVInjectedRecorder.Scenario(rawValue: env["DICTATE_E2E_SCENARIO"] ?? "headset_zeros") ?? .headsetZeros
        let seconds = Double(try WAVInjectedRecorder.parseWAV(at: wav).count) / 24_000
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        // DICTATE_E2E_HINTS: the user's vocab-hints.txt, the whisper prompt production uses.
        if let hints = env["DICTATE_E2E_HINTS"] {
            try FileManager.default.createDirectory(at: paths.vocabularyURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: hints), to: paths.vocabularyURL)
        }
        let keys = KeyStore(reader: { _ in key })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-e2e-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let recorder = WAVInjectedRecorder(url: wav, pace: 1.0, scenario: scenario)
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { TestApple("") },
            sttTransport: URLSessionTransport(timeout: 30), groqCleanupTransport: TestHTTP(""),
            localCleanupTransport: TestHTTP(""), inserter: TextInserter(pasteboard: clipboard, postKeystroke: {}),
            panelFactory: { TestPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.e2e") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .captureOnly,
                                       dependencies: dependencies)
        let engine = DictationEngine(controller: controller)
        final class Notes: @unchecked Sendable { let lock = NSLock(); var lines: [String] = [] }
        let sink = Notes()
        engine.onDiagnostic = { line in sink.lock.withLock { sink.lines.append(line) } }
        defer { engine.onDiagnostic = nil }
        var deliveries: [(String, DictationTimeline)] = []
        engine.onTranscript = { deliveries.append(($0, $1)) }
        engine.start()
        try await Task.sleep(nanoseconds: UInt64((seconds + 1.0) * 1_000_000_000))
        engine.finish()
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline, deliveries.isEmpty || !FileManager.default.fileExists(atPath: paths.logURL.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let log = (try? String(contentsOf: paths.logURL, encoding: .utf8)) ?? ""
        let outcome = log.split(separator: "\n").last { $0.contains("outcome=") }.map(String.init) ?? "no outcome line"
        let all = sink.lock.withLock { sink.lines }
        let timeline = all.last { $0.contains("timeline:") } ?? ""
        let bridge = timeline.split(separator: " ").filter {
            $0.hasPrefix("bridge_src=") || $0.hasPrefix("bridge_reason=") || $0.hasPrefix("headset_restart")
        }.joined(separator: " ")
        let text = deliveries.first?.0 ?? ""
        let names = ShadowScore.nameCount(text)
        let fields = outcome.split(separator: " ").filter { field in
            ["duration=", "outcome=", "path=", "chars="].contains { field.hasPrefix($0) }
        }.joined(separator: " ")
        print("E2E scenario=\(scenario.rawValue) \(fields) \(bridge) names=\(names)/4 " +
              String(format: "overlap=%.2f", ShadowScore.overlap(text)) +
              " matched=\(ShadowScore.names.filter { text.contains($0) }.joined(separator: ","))" +
              " hints=\(env["DICTATE_E2E_HINTS"] == nil ? 0 : 1) fallback_note=\(all.contains { $0.contains("bridge_src=builtin_fallback reason=headset_digital_silence") } ? 1 : 0)")
        #expect(outcome.contains("outcome=ok"))
        #expect(names == 4)
        if scenario == .headsetZeros { #expect(bridge.contains("bridge_src=builtin_fallback")) }
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

    // A host's single ⌥ tap must pre-start capture like the standalone app (BT3/D0b), not be a no-op finish.
    @Test func hostTapPrestartsCaptureWhenIdle() async throws {
        let recorder = TestRecorder()
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { TestApple("x") }, sttTransport: TestHTTP("x"),
            groqCleanupTransport: TestHTTP("x"), localCleanupTransport: TestHTTP("x"), inserter: TextInserter(),
            panelFactory: { TestPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { nil }, manageMedia: false)
        let controller = AppController(keyStore: KeyStore(reader: { _ in "fixture" }),
            paths: AppPaths(home: URL(fileURLWithPath: "/unused")), surface: .none, mode: .dictate, dependencies: dependencies)
        let engine = DictationEngine(controller: controller)
        engine.finish()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.starts == 0)   // finish() stays a no-op while idle
        engine.tap()
        try await waitFor { recorder.starts == 1 }
        engine.cancel()
    }

    // While a held/error outcome is up, the first ⌥ of the next ⌥⌥ must still pre-start capture.
    @Test func tapPrestartsEvenWhileARecoverableOutcomeIsShown() async throws {
        let recorder = TestRecorder()
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { TestApple("") }, sttTransport: TestHTTP(""),
            groqCleanupTransport: TestHTTP(""), localCleanupTransport: TestHTTP(""), inserter: TextInserter(),
            panelFactory: { TestPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { nil }, manageMedia: false)
        let controller = AppController(keyStore: KeyStore(reader: { _ in throw URLError(.userAuthenticationRequired) }),
            paths: AppPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("dictate-outcome-\(UUID().uuidString)")),
            surface: .none, mode: .dictate, dependencies: dependencies)
        let engine = DictationEngine(controller: controller)
        var states: [DictateAppKit.DictationState] = []
        engine.onState = { states.append($0) }
        engine.start()
        try await waitFor { recorder.ready && recorder.starts > 0 && !controller.micStartPending }
        engine.finish()
        try await waitFor { states.contains { if case .error = $0 { return true }; if case .held = $0 { return true }; return false } }
        try await waitFor { !recorder.isAllocated }
        let before = recorder.starts
        engine.tap()
        try await waitFor { recorder.starts > before }
        engine.escape()
    }

    @Test func keepWarmIsNeverScheduledWithFakeDependenciesAndSharesTheSTTSession() async throws {
        let recorder = TestRecorder()
        let stt = TestHTTP("x"), groq = TestHTTP("x"), local = TestHTTP("x")
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { TestApple("x") }, sttTransport: stt,
            groqCleanupTransport: groq, localCleanupTransport: local, inserter: TextInserter(),
            panelFactory: { TestPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { nil }, manageMedia: false)
        let fake = AppController(keyStore: KeyStore(reader: { _ in "fixture" }),
            paths: AppPaths(home: URL(fileURLWithPath: "/unused")), surface: .none, mode: .dictate, dependencies: dependencies)
        fake.configureEngine()
        fake.engineHotkey(.tap)   // the first-tap warm-up path
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!fake.keepWarmScheduled && fake.keepWarmPings == 0)
        let sttRequests = await stt.requests.count
        #expect(sttRequests == 0)
        // Positive control: the production wiring (no injected fakes) does own a scheduler. Nothing is pinged until activity.
        let real = AppController(keyStore: KeyStore(reader: { _ in "fixture" }),
            paths: AppPaths(home: URL(fileURLWithPath: "/unused")), surface: .none, mode: .dictate)
        #expect(real.keepWarmScheduled == (GroqKeepWarm.isEnabled() && ProcessInfo.processInfo.environment["DICTATE_FAKE_TRANSCRIPT"] == nil))
        #expect(real.keepWarmPings == 0)
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
            var axTexts: [String]? = []
            let inserter = TextInserter(
                pasteboard: clipboard,
                postKeystroke: {
                    pastes += 1
                    axTexts = [clean]
                },
                pollInterval: 0.01,
                axReader: { axTexts }
            )
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
            // BT3 resets pre-roll before the asynchronous start; wait for the start itself.
            try await waitFor { recorder.ready && recorder.starts > 0 && !controller.micStartPending }
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

    @Test func quotaPolicyChoosesFallbackPerEndpoint() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func quota(stt: Int, cleanup: Int) -> GroqQuota {
            func r(_ n: Int, _ e: GroqRateLimit.Endpoint) -> GroqRateLimit {
                GroqRateLimit(response: HTTPURLResponse(url: URL(string: "https://api.groq.com")!, statusCode: 200, httpVersion: nil,
                    headerFields: ["x-ratelimit-limit-requests": "100", "x-ratelimit-remaining-requests": "\(n)",
                                   "x-ratelimit-reset-requests": "2m0s"])!, endpoint: e)
            }
            return GroqQuota().merging(r(stt, .stt), at: now).merging(r(cleanup, .cleanup), at: now)
        }
        let ok = EnginePolicy(mode: .dictate, fallback: nil, quota: quota(stt: 50, cleanup: 50), now: now)
        #expect(ok.usesGroqSTT && ok.usesGroqCleanup && ok.fallbackLabel == nil && ok.fallbackFields == nil)
        let stt = EnginePolicy(mode: .dictate, fallback: nil, quota: quota(stt: 9, cleanup: 50), now: now)
        #expect(!stt.usesGroqSTT && stt.usesGroqCleanup && stt.fallbackLabel == "quota")
        #expect(stt.fallbackFields == "quota quota_low=stt")
        let cleanup = EnginePolicy(mode: .dictate, fallback: nil, quota: quota(stt: 50, cleanup: 9), now: now)
        #expect(cleanup.usesGroqSTT && !cleanup.usesGroqCleanup && cleanup.fallbackLabel == "quota")
        #expect(cleanup.fallbackFields == "quota quota_low=cleanup")
        let both = EnginePolicy(mode: .dictate, fallback: nil, quota: quota(stt: 1, cleanup: 1), now: now)
        #expect(!both.usesGroqSTT && !both.usesGroqCleanup && both.fallbackFields == "quota quota_low=both")
        // Capture-only never cleans up, so a low cleanup quota is not a fallback.
        let capture = EnginePolicy(mode: .captureOnly, fallback: nil, quota: quota(stt: 50, cleanup: 1), now: now)
        #expect(capture.usesGroqSTT && capture.fallbackLabel == nil)
        // Expired counts no longer force a fallback.
        let expired = EnginePolicy(mode: .dictate, fallback: nil, quota: quota(stt: 1, cleanup: 1), now: now.addingTimeInterval(121))
        #expect(expired.usesGroqSTT && expired.usesGroqCleanup && expired.fallbackLabel == nil)
        // The manual override still means both, without a quota_low field.
        let forced = EnginePolicy(mode: .dictate, fallback: .quota, quota: quota(stt: 50, cleanup: 50), now: now)
        #expect(!forced.usesGroqSTT && !forced.usesGroqCleanup && forced.fallbackFields == "quota")
    }

    // No key (denied / prompt suppressed): straight to Apple STT + local cleanup, no Groq attempts.
    @Test func unavailableKeyRoutesToAppleAndLocal() {
        var policy = EnginePolicy(mode: .dictate, fallback: nil)
        policy.keyUnavailable = true
        #expect(!policy.usesGroqSTT && !policy.usesGroqCleanup)
        #expect(policy.fallbackFields == "no_key")
        var forced = EnginePolicy(mode: .dictate, fallback: .quota)
        forced.keyUnavailable = true
        #expect(forced.fallbackFields == "quota")
    }

    @Test func lowSTTQuotaRoutesSessionToAppleAndRecordsCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-d3-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        let quotaFile = root.appendingPathComponent("host/groq-quota.json")
        // Seed a host-relocated file: STT at 5/100 with a reset an hour away.
        GroqQuotaStore(fileURL: quotaFile).record(GroqRateLimit(response: HTTPURLResponse(
            url: URL(string: "https://api.groq.com")!, statusCode: 200, httpVersion: nil,
            headerFields: ["x-ratelimit-limit-requests": "100", "x-ratelimit-remaining-requests": "5",
                           "x-ratelimit-reset-requests": "1h0m0s"])!, endpoint: .stt))
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let raw = "please send the whole report on Tuesday"
        let clean = "Please send the whole report on Tuesday."
        let recorder = TestRecorder()
        let apple = TestApple(raw)
        let stt = TestHTTP(raw), groq = TestHTTP(clean), local = TestHTTP(clean)
        let panel = TestPanel()
        let clipboard = NSPasteboard(name: .init("dictate-d3-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        var pastes = 0
        var confirmedTexts: [String]? = []
        let inserter = TextInserter(pasteboard: clipboard, postKeystroke: { pastes += 1; confirmedTexts = [clean] },
                                    axReader: { confirmedTexts })
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { apple }, sttTransport: stt,
            groqCleanupTransport: groq, localCleanupTransport: local, inserter: inserter,
            panelFactory: { panel }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate,
                                       dependencies: dependencies, quotaFileURL: quotaFile)
        let engine = DictationEngine(controller: controller)
        #expect(engine.quotaFileURL == quotaFile)
        #expect(engine.groqQuota.stt.remainingRequests == 5)
        var deliveries: [(String, DictationTimeline)] = []
        engine.onTranscript = { deliveries.append(($0, $1)) }
        engine.start()
        try await waitFor { recorder.ready && recorder.starts > 0 && !controller.micStartPending }
        recorder.onLevel?(2); recorder.onLevel?(-1)
        engine.finish()
        try await waitFor { !deliveries.isEmpty }
        try await waitFor { FileManager.default.fileExists(atPath: paths.logURL.path) }
        #expect(deliveries[0].1.path == "apple" && deliveries[0].1.fallback == "quota")
        #expect(await stt.requests.isEmpty)                    // STT low: no Groq STT
        let groqCleanups = await groq.requests.filter { $0.url!.path.hasSuffix("/chat/completions") }.count
        let localCalls = await local.requests.count
        #expect(groqCleanups == 1 && localCalls == 0)          // cleanup still on Groq (warm-up GET /models aside)
        let line = try String(contentsOf: paths.logURL, encoding: .utf8)
        #expect(line.contains("fallback=quota quota_low=stt"))
        // The cleanup response's counts were recorded; the STT counts were not disturbed.
        #expect(engine.groqQuota.cleanup.remainingRequests == 42)
        #expect(engine.groqQuota.stt.remainingRequests == 5)
        let file = try String(contentsOf: quotaFile, encoding: .utf8)
        #expect(!file.contains("gsk_") && !file.contains("Bearer") && !file.contains(raw))
    }

    @Test func cleanup429RetriesOnSecondGroqModelBeforeLocal() async throws {
        let groqPayload = try! JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Groq retry winner."]]]
        ])
        let groqTransport = TestSequenceTransport(responses: [
            (status: 429, body: "{\"error\":{\"message\":\"Rate limit exceeded\"}}"),
            (status: 200, body: String(decoding: groqPayload, as: UTF8.self))
        ])
        let localPayload = try! JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Local winner."]]]
        ])
        let localTransport = TestSequenceTransport(responses: [
            (status: 200, body: String(decoding: localPayload, as: UTF8.self))
        ])

        let groq = TranscriptCleaner(transport: groqTransport, endpoint: TranscriptCleaner.groqEndpoint,
                                     model: "qwen/qwen3.8-27b", vocabulary: "", apiKey: { "k" })
        let local = TranscriptCleaner(transport: localTransport, endpoint: TranscriptCleaner.ollamaEndpoint,
                                      model: "llama3.2:3b", vocabulary: "", apiKey: { "k" })

        let result = await AppController.cleanUp("raw text to clean", groq: groq, local: local)

        #expect(result.text == "Groq retry winner.")
        #expect(result.label == "cleanup_model_fallback=groq:gpt-oss-20b")
        #expect(result.model == TranscriptCleaner.retryModel)
        #expect(result.calls == 2)

        let groqRequests = await groqTransport.requests
        #expect(groqRequests.count == 2)
        let body0 = try JSONSerialization.jsonObject(with: groqRequests[0].httpBody!) as! [String: Any]
        let body1 = try JSONSerialization.jsonObject(with: groqRequests[1].httpBody!) as! [String: Any]
        #expect(body0["model"] as? String == "qwen/qwen3.8-27b")
        #expect(body1["model"] as? String == TranscriptCleaner.retryModel)

        let localRequests = await localTransport.requests
        #expect(localRequests.count == 0)
    }

    @Test func cleanup429BothGroqFailFallsBackToLocal() async throws {
        let groqTransport = TestSequenceTransport(responses: [
            (status: 429, body: "{\"error\":{\"message\":\"Rate limit exceeded\"}}"),
            (status: 429, body: "{\"error\":{\"message\":\"Rate limit exceeded\"}}")
        ])
        let localPayload = try! JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Local winner."]]]
        ])
        let localTransport = TestSequenceTransport(responses: [
            (status: 200, body: String(decoding: localPayload, as: UTF8.self))
        ])

        let groq = TranscriptCleaner(transport: groqTransport, endpoint: TranscriptCleaner.groqEndpoint,
                                     model: "qwen/qwen3.8-27b", vocabulary: "", apiKey: { "k" })
        let local = TranscriptCleaner(transport: localTransport, endpoint: TranscriptCleaner.ollamaEndpoint,
                                      model: "llama3.2:3b", vocabulary: "", apiKey: { "k" })

        let result = await AppController.cleanUp("raw text to clean", groq: groq, local: local)

        #expect(result.text == "Local winner.")
        #expect(result.label == "fallback_local")
        #expect(result.model == "llama3.2:3b")
        #expect(result.calls == 3)

        let groqRequests = await groqTransport.requests
        #expect(groqRequests.count == 2)
        let localRequests = await localTransport.requests
        #expect(localRequests.count == 1)
    }

    @Test func cleanupNon429ErrorDoesNotRetryGroqBeforeLocal() async throws {
        let groqTransport = TestSequenceTransport(responses: [
            (status: 500, body: "{\"error\":{\"message\":\"Internal server error\"}}")
        ])
        let localPayload = try! JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Local winner."]]]
        ])
        let localTransport = TestSequenceTransport(responses: [
            (status: 200, body: String(decoding: localPayload, as: UTF8.self))
        ])

        let groq = TranscriptCleaner(transport: groqTransport, endpoint: TranscriptCleaner.groqEndpoint,
                                     model: "qwen/qwen3.8-27b", vocabulary: "", apiKey: { "k" })
        let local = TranscriptCleaner(transport: localTransport, endpoint: TranscriptCleaner.ollamaEndpoint,
                                      model: "llama3.2:3b", vocabulary: "", apiKey: { "k" })

        let result = await AppController.cleanUp("raw text to clean", groq: groq, local: local)

        #expect(result.text == "Local winner.")
        #expect(result.label == "fallback_local")
        #expect(result.model == "llama3.2:3b")
        #expect(result.calls == 2)

        let groqRequests = await groqTransport.requests
        #expect(groqRequests.count == 1)
        let localRequests = await localTransport.requests
        #expect(localRequests.count == 1)
    }
}

private actor TestSequenceTransport: HTTPTransport {
    private var responses: [(status: Int, body: String)]
    private(set) var requests: [URLRequest] = []
    init(responses: [(status: Int, body: String)]) {
        self.responses = responses
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw URLError(.timedOut)
        }
        let next = responses.removeFirst()
        return (Data(next.body.utf8), HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!)
    }
}


extension DictationEngineTests {
    @Test func pasteOutcomeWaitsForConfirmationAndTimeoutOffersRecovery() async throws {
        for confirms in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v53-outcome-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = AppPaths(home: root)
            let keys = KeyStore(reader: { _ in "fixture" })
            keys.prefetch(services: ["groq-api"])
            try await waitFor { keys.key(for: "groq-api") != nil }
            let pb = NSPasteboard(name: .init("dictate-v53-outcome-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.setString("ORIGINAL", forType: .string)
            let clock = V15PasteConfirmationTests.ManualMainScheduler()
            let ax = V15PasteConfirmationTests.AXMockBox()
            let words = "Please send the whole report on Tuesday."
            let recorder = TestRecorder()
            var posted = false
            let inserter = TextInserter(pasteboard: pb, postKeystroke: { posted = true },
                schedule: clock.schedule, axReader: { ax.texts }, now: { clock.now })
            let deps = EngineDependencies(recorder: recorder, makeApple: { TestApple(words) },
                sttTransport: TestHTTP(words), groqCleanupTransport: TestHTTP(words), localCleanupTransport: TestHTTP(words),
                inserter: inserter, panelFactory: { TestPanel() }, requestMicrophoneAccess: { $0(true) },
                frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
            let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate, dependencies: deps)
            let engine = DictationEngine(controller: controller)
            var states: [DictateAppKit.DictationState] = []
            engine.onState = { states.append($0) }
            engine.start()
            try await waitFor { recorder.ready && recorder.starts > 0 && !controller.micStartPending }
            engine.finish()
            try await waitFor { posted }
            let before = (try? String(contentsOf: paths.logURL, encoding: .utf8)) ?? ""
            print("R0 PASTE_UI pending=\(!states.contains(.pasted)) logged_ok=\(before.contains("outcome=ok"))")
            #expect(!states.contains(.pasted))
            #expect(!before.contains("outcome=ok"))
            if confirms { ax.texts = [words] }
            clock.advance(to: confirms ? 0.2 : 10.1)
            if confirms { #expect(states.last == .pasted) }
            else { #expect(states.last == .held(preview: words)); #expect(!states.contains(.pasted)) }
            let after = try String(contentsOf: paths.logURL, encoding: .utf8)
            #expect(after.contains(confirms ? "outcome=ok" : "outcome=held:paste_timeout"))
            #expect(pb.string(forType: .string) == (confirms ? "ORIGINAL" : words))
            engine.cancel()
        }
    }

    @Test func heldPasteRecoveryWaitsForItsOwnConfirmation() async throws {
        let outcome = PillOutcome(.held("paste_timeout"), hasText: true)
        #expect(outcome.label == "paste unconfirmed · tap to retry")
        #expect(outcome.showsPasteAffordance)
        for confirms in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v53-recovery-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = AppPaths(home: root)
            let keys = KeyStore(reader: { _ in "fixture" })
            let pb = NSPasteboard(name: .init("dictate-v53-recovery-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents()
            pb.setString("ORIGINAL", forType: .string)
            let clock = V15PasteConfirmationTests.ManualMainScheduler()
            let ax = V15PasteConfirmationTests.AXMockBox()
            let words = "WORDS"
            var posted = 0
            let inserter = TextInserter(
                pasteboard: pb,
                postKeystroke: {
                    posted += 1
                    if !confirms && posted == 1 {
                        clock.schedule(0.2) {
                            pb.clearContents()
                            pb.setString("NEWER_COPY", forType: .string)
                        }
                    }
                },
                schedule: clock.schedule,
                axReader: { ax.texts },
                now: { clock.now }
            )
            let deps = EngineDependencies(
                recorder: TestRecorder(),
                makeApple: { TestApple(words) },
                sttTransport: TestHTTP(words),
                groqCleanupTransport: TestHTTP(words),
                localCleanupTransport: TestHTTP(words),
                inserter: inserter,
                panelFactory: { TestPanel() },
                requestMicrophoneAccess: { $0(true) },
                frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") },
                manageMedia: false
            )
            let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate, dependencies: deps)
            let engine = DictationEngine(controller: controller)
            controller.configureEngine()
            var states: [DictateAppKit.DictationState] = []
            engine.onState = { states.append($0) }
            controller.showOutcome(.held("paste_timeout"), text: words)
            #expect(states.last == .held(preview: words))
            states.removeAll()
            engine.pasteHeld()
            try await waitFor { posted == 1 }
            let pending = !states.contains(.pasted) && states.last == .transcribing
            #expect(!states.contains(.pasted))
            #expect(states.last == .transcribing)
            if confirms {
                ax.texts = [words]
                clock.advance(to: 0.2)
                let clipboard = pb.string(forType: .string) ?? "nil"
                print("R0 RECOVERY pending=\(pending) confirmed=\(states.last == .pasted) clipboard=\(clipboard) reason=ok")
                #expect(states.last == .pasted)
                #expect(clipboard == "ORIGINAL")
            } else {
                clock.advance(to: 10.1)
                let clipboard = pb.string(forType: .string) ?? "nil"
                print("R0 RECOVERY pending=\(pending) confirmed=\(states.contains(.pasted)) clipboard=\(clipboard) reason=paste_timeout")
                #expect(!states.contains(.pasted))
                #expect(states.last == .held(preview: words))
                #expect(clipboard == "NEWER_COPY")
                engine.pasteHeld()
                for _ in 0..<100 where posted < 2 {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                #expect(posted == 2)
                ax.texts = [words]
                clock.advance(to: 10.3)
                #expect(states.last == .pasted)
            }
            engine.cancel()
        }
    }
}


/// C2 exercises the existing held outcome through the public engine with fake capture,
/// providers, panel, focus, AX, event posting, private pasteboard and a virtual insertion clock.
@MainActor @Suite(.serialized)
struct V18TypedEngineTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for fake typed pipeline")
        throw URLError(.timedOut)
    }

    @Test(arguments: [false, true])
    func typedTimeoutAndCancellationPreserveEngineRecovery(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-c2-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(home: root)
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let f = V18TypedInsertionTests.Fixture()
        f.confirmsTyping = false
        let words = (0..<91).map { "token\($0)" }.joined(separator: " ")
        let recorder = TestRecorder()
        let deps = EngineDependencies(recorder: recorder, makeApple: { TestApple(words) },
            sttTransport: TestHTTP(words), groqCleanupTransport: TestHTTP(words), localCleanupTransport: TestHTTP(words),
            inserter: f.inserter, panelFactory: { TestPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "fixture.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate, dependencies: deps)
        let engine = DictationEngine(controller: controller)
        var states: [DictateAppKit.DictationState] = []
        engine.onState = { states.append($0) }
        let baseline = f.pb.changeCount
        engine.start()
        try await waitFor { recorder.ready && recorder.starts > 0 && !controller.micStartPending }
        engine.finish()
        try await waitFor { !f.poster.posted.isEmpty }
        let typedPayload = String(decoding: f.poster.prepared.filter(\.keyDown).flatMap(\.utf16), as: UTF16.self)
        #expect(!typedPayload.isEmpty)
        #expect(typedPayload == words)
        #expect(!states.contains(.pasted))
        f.clock.advance(to: cancel ? 0.03 : 9.9)
        let count = f.poster.posted.count
        let expectedRecovery = cancel ? String(typedPayload.dropFirst(f.typed.count)) : typedPayload
        if cancel { engine.escape() }
        f.clock.advance(to: 10.1)
        #expect(f.inserter.heldText == expectedRecovery)
        #expect(states.last == .held(preview: expectedRecovery))
        #expect(!states.contains(.pasted))
        #expect(f.poster.pasteCount == 0)
        #expect(f.pb.changeCount == baseline)
        if cancel { #expect(f.poster.posted.count == count) }
        let sessionLog = try String(contentsOf: paths.logURL, encoding: .utf8)
        #expect(sessionLog.contains("outcome=held:paste_timeout"))
        #expect(!sessionLog.contains(typedPayload))
        print("C2 ENGINE action=\(cancel ? "escape" : "timeout") outcome=held:paste_timeout recovery_chars=\(expectedRecovery.count) clipboard_changecount_delta=0")
        engine.cancel()
    }
}
