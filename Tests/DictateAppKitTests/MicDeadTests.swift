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
    let text: String
    init(_ text: String) { self.text = text }
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { text }
    func cancel() {}
}
private actor HTTP: HTTPTransport {
    let text: String
    let delay: UInt64
    private(set) var requests = 0
    init(_ text: String, delayMs: UInt64 = 0) { self.text = text; self.delay = delayMs * 1_000_000 }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        let payload: [String: Any] = request.url!.path.contains("transcriptions") ? ["text": text] :
            ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
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

/// v1.8 L2/L5 through the injected recorder (the production feed + health clock on a media
/// clock) and the production controller. No hardware, no network (fake transports).
/// Recorder-level scenarios run off the main actor (WAV generation/parsing would stall it).
@Suite("MicDeadRecorder")
struct MicDeadRecorderTests {
    private static func tone(seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
    }
    private func wav(seconds: Double) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-micdead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = Self.tone(seconds: seconds)
        let url = dir.appendingPathComponent("tone.wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1).write(to: url)
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

    /// Runs a scenario at 20× until it fails or `mediaSeconds` of media time pass.
    private func run(_ scenario: WAVInjectedRecorder.Scenario, mediaSeconds: Double, legacy: Bool = false) async throws
        -> (failure: CaptureFailure?, notes: [String], pcm: [Int16], wav: [Int16], stats: AudioRecorder.CaptureStats) {
        // Longer than any run: the WAV's trailing zeros must never be what the clock sees.
        let (dir, url) = try wav(seconds: 7)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: scenario, legacyRecoveryTiming: legacy)
        let notes = Lines()
        let pcmLock = NSLock()
        var pcm: [Int16] = []
        var failure: CaptureFailure?
        recorder.note = { notes.add($0) }
        recorder.mediaLimit = mediaSeconds + 0.2          // never past the 7 s WAV, however late stop() runs
        recorder.onPCMChunk = { chunk in pcmLock.withLock { pcm += chunk } }
        recorder.onCaptureFailure = { failure = $0 }
        try recorder.start()
        recorder.resetCapture()
        let deadline = ContinuousClock.now + .milliseconds(Int(mediaSeconds * 50) + 3_000)
        while failure == nil, pcmLock.withLock({ pcm.count }) < Int(mediaSeconds * 24_000), ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = recorder.stop()
        return (failure, notes.snapshot, pcmLock.withLock { pcm }, Self.tone(seconds: 7), recorder.stats)
    }

    // v1.9 L1: sco_torn_down_250ms — the immediate re-attach keeps the route; v1.8's debounce loses it.
    @Test func scoTornDown250msImmediateReattachHeadsetCarriesGreen() async throws {
        let result = try await run(.scoTornDown250ms, mediaSeconds: 3)
        #expect(result.failure == nil)
        #expect(result.notes.contains("bt_recovery=immediate path=configuration engine_running=0 after_ms=0"))
        #expect(!result.notes.contains { $0.hasPrefix("bridge_src=builtin_fallback") })
        #expect(result.stats.bridgeSource == "builtin")             // bridged, then the headset took over
        #expect(Array(result.pcm.prefix(3 * 24_000)) == Array(result.wav.prefix(3 * 24_000)))
    }

    @Test func scoTornDown250msV18DebounceFallsBackRed() async throws {
        let result = try await run(.scoTornDown250ms, mediaSeconds: 3, legacy: true)
        #expect(result.failure == nil)
        #expect(result.notes.contains("bt_recovery=queued path=configuration wait_ms=200"))
        #expect(result.notes.contains("bridge_src=builtin_fallback reason=headset_digital_silence"))
        #expect(result.stats.bridgeSource == "builtin_fallback")
        #expect(Array(result.pcm.prefix(3 * 24_000)) == Array(result.wav.prefix(3 * 24_000)))   // the built-in still carries
    }

    @Test func builtinDiesScenarioEndsWithMicDeadWithin2s() async throws {
        let result = try await run(.builtinDies, mediaSeconds: 6)
        let failure = try #require(result.failure)
        #expect(failure.reason == .micDead && failure.health == .staleBuiltin)
        #expect(failure.lastDeliveryMs == 400)                               // media clock: the last buffer starts at 0.4 s
        #expect(failure.durationSeconds <= 0.5 + CaptureHealth.failAfter + 0.11)
        #expect(failure.bytes > 44 && failure.sources == "builtin:dead,headset:zeros")
        #expect(result.notes.contains("health=warn reason=stale_builtin"))
        #expect(result.notes.contains { $0.hasPrefix("fail reason=mic_dead health=stale_builtin") })
        #expect(!result.notes.contains("bridge_src=builtin_fallback reason=headset_digital_silence"))
        #expect(Array(result.pcm.prefix(12_000)) == Array(result.wav.prefix(12_000)))   // the 0.5 s it heard
    }

    @Test func headsetZerosScenarioWithALiveBuiltinNeverFailsGreen() async throws {
        let result = try await run(.headsetZeros, mediaSeconds: 3.5)
        #expect(result.failure == nil)
        #expect(!result.notes.contains { $0.hasPrefix("health=warn") })
        #expect(result.notes.contains("fallback_check builtin_fresh_at_fallback=1 builtin_age_ms=0"))
        #expect(Array(result.pcm.prefix(3 * 24_000)) == Array(result.wav.prefix(3 * 24_000)))
    }

    @Test func builtinDriftsScenarioIsDeadThenMicDead() async throws {
        let result = try await run(.builtinDrifts, mediaSeconds: 6)
        #expect(result.notes.contains("bridge_device_check=drift from=154 fixed=0"))
        #expect(result.notes.contains { $0.hasPrefix("bridge_builtin_lost=1 reason=drift") })
        let failure = try #require(result.failure)
        #expect(failure.reason == .micDead && failure.sources == "builtin:drift,headset:zeros")
        #expect(failure.durationSeconds <= 0.5 + CaptureHealth.failAfter + 0.11)
    }

    @Test func pcmCallbackThatStopsTheRecorderDoesNotDeadlock() async throws {
        let (dir, url) = try wav(seconds: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        for stopsInCallback in [true, false] {
            let recorder = WAVInjectedRecorder(url: url, pace: 0.05)
            let lock = NSLock()
            var chunks: [[Int16]] = []
            recorder.onPCMChunk = { chunk in
                let count = lock.withLock { chunks.append(chunk); return chunks.count }
                if stopsInCallback, count == 3 { _ = recorder.stop() }        // re-enters the recorder
            }
            try recorder.start()
            recorder.resetCapture()
            try await waitFor { lock.withLock { chunks.count >= 3 } }
            try await Task.sleep(nanoseconds: 30_000_000)
            _ = recorder.stop()
            let got = lock.withLock { chunks }
            let wavSamples = Self.tone(seconds: 2)
            #expect(got.count >= 3)                                           // GREEN control delivers
            #expect(Array(got.prefix(3).joined()) == Array(wavSamples.prefix(3 * 2_400)))   // in order
            if stopsInCallback { #expect(got.count == 3 && !recorder.isRunning) }       // nothing after stop
        }
    }

    @Test func micDeadOutcomeWordAndLegacyWords() {
        #expect(PillOutcome(.error("mic_dead")).label == "no mic signal")
        #expect(DictateAppKit.DictationState.outcome(.error("mic_dead")) == .error(word: "no mic signal"))
        #expect(PillOutcome(.error("mic_start")).label == "no mic")                    // unchanged
        #expect(DictationOutcome.error("mic_dead").label == "error:mic_dead")
        let failure = CaptureFailure(reason: .micDead, health: .zeros, durationSeconds: 2.53, bytes: 24_044,
                                     framesKept: 12_000, lastDeliveryMs: 500, sources: "builtin:dead,headset:zeros")
        #expect(failure.note == "fail reason=mic_dead health=zeros kept_ms=500 last_delivery_ms=500 duration_ms=2530 bytes=24044 sources=builtin:dead,headset:zeros")
    }

}

@Suite("MicDead") @MainActor
struct MicDeadTests {
    private static func tone(seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
    }
    private func wav(seconds: Double) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-micdead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = Self.tone(seconds: seconds)
        let url = dir.appendingPathComponent("tone.wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1).write(to: url)
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

    /// The engine's own session notes through the real gate: a mic_dead dictation FAILs, a
    /// three-phrase dictation carried by the built-in beside a silent headset PASSes (synthetic
    /// media clock; parser + engine agreement, not live hardware proof).
    @Test func engineSessionNotesDriveBtProof() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for scenario in [WAVInjectedRecorder.Scenario.builtinDies, .headsetZeros] {
            // Three 0.6 s phrases separated by 0.4 s of quiet room noise, then 3 s more room noise.
            var samples: [Int16] = []
            for phrase in 0..<3 {
                samples += (0..<14_400).map { Int16(8_000 * sin(Double($0 + phrase) * 2 * .pi * 220 / 24_000)) }
                samples += (0..<9_600).map { $0 % 2 == 0 ? 24 : -24 }
            }
            samples += (0..<72_000).map { $0 % 2 == 0 ? 24 : -24 }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-gate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("phrases.wav")
            try WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1).write(to: url)
            let paths = AppPaths(home: dir.appendingPathComponent("home"))
            let keys = KeyStore(reader: { _ in "fixture" })
            keys.prefetch(services: ["groq-api"])
            try await waitFor { keys.key(for: "groq-api") != nil }
            let clipboard = NSPasteboard(name: .init("dictate-gate-\(UUID().uuidString)"))
            defer { clipboard.releaseGlobally() }
            let recorder = WAVInjectedRecorder(url: url, pace: 0.1, scenario: scenario)
            let notes = Lines()
            recorder.note = { notes.add($0) }
            let dependencies = EngineDependencies(recorder: recorder, makeApple: { Apple("please send the report") },
                sttTransport: HTTP("please send the report"), groqCleanupTransport: HTTP(""), localCleanupTransport: HTTP(""),
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
            if scenario == .headsetZeros {
                try await waitFor { levels >= 34 }                          // ≥ 3.3 s of media: all three phrases
                engine.finish()
            }
            try await waitFor { notes.snapshot.contains { $0.contains("event=end") } }
            // Stamp the engine's lines in emission order (10 ms apart) as the gate's input.
            let base = Date(timeIntervalSince1970: 1_800_000_000)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let stream = notes.snapshot.enumerated().map { index, line in
                "\(formatter.string(from: base.addingTimeInterval(Double(index) * 0.01))) dictate: \(line)"
            }.joined(separator: "\n") + "\n"
            let input = dir.appendingPathComponent("stream.log")
            try stream.write(to: input, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("tools/bt-proof.sh").path, "--from-file", input.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let last = output.split(separator: "\n").last.map(String.init) ?? ""
            if scenario == .builtinDies {
                #expect(process.terminationStatus == 1)
                #expect(last.hasPrefix("BT-PROOF: FAIL outcome=error:mic_dead"))
            } else {
                #expect(process.terminationStatus == 0, "\(output)")
                #expect(last == "BT-PROOF: PASS")
            }
        }
    }

    /// N3 (re-review): Escape while the outcome is still transcribing closes that session exactly
    /// once (as `cancel`); the abandoned transcription closes nothing.
    @Test func cancelDuringTranscriptionClosesTheSessionOnce() async throws {
        let (dir, url) = try wav(seconds: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppPaths(home: dir.appendingPathComponent("home"))
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-cancel-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05)
        recorder.note = { _ in }
        let stt = HTTP("please send the report", delayMs: 400)
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { Apple("please send the report") },
            sttTransport: stt, groqCleanupTransport: HTTP(""), localCleanupTransport: HTTP(""),
            inserter: TextInserter(pasteboard: clipboard, postKeystroke: {}),
            panelFactory: { Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .captureOnly,
                                       dependencies: dependencies)
        let notes = Lines()
        controller.onSessionNote = { notes.add($0) }
        let engine = DictationEngine(controller: controller)
        var states: [DictateAppKit.DictationState] = []
        engine.onState = { states.append($0) }
        engine.start()
        try await Task.sleep(nanoseconds: 60_000_000)
        engine.finish()
        try await waitFor { states.contains(.transcribing) }
        engine.cancel()                                                      // Escape while transcribing
        try await Task.sleep(nanoseconds: 900_000_000)                       // the slow STT has returned by now
        let ends = notes.snapshot.filter { $0.contains("event=end") }
        #expect(ends.count == 1 && ends.first?.contains("outcome=cancel") == true)
        let log = try String(contentsOf: paths.logURL, encoding: .utf8).split(separator: "\n")
        #expect(log.count == 1 && log.first?.contains("outcome=cancel") == true)
    }

    /// mic_dead_propagates_to_host: health failure → lifecycle → controller → dictate.log + pill word,
    /// no STT, no paste; GREEN: the same controller with a live built-in finishes `ok`.
    @Test func micDeadPropagatesToTheLogAndThePill() async throws {
        for scenario in [WAVInjectedRecorder.Scenario.builtinDies, .headsetZeros] {
            let (dir, url) = try wav(seconds: 3)
            defer { try? FileManager.default.removeItem(at: dir) }
            let paths = AppPaths(home: dir.appendingPathComponent("home"))
            let keys = KeyStore(reader: { _ in "fixture" })
            keys.prefetch(services: ["groq-api"])
            try await waitFor { keys.key(for: "groq-api") != nil }
            let stt = HTTP("please send the report")
            var pastes = 0
            let clipboard = NSPasteboard(name: .init("dictate-micdead-\(UUID().uuidString)"))
            defer { clipboard.releaseGlobally() }
            let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: scenario)
            let notes = Lines()
            recorder.note = { notes.add($0) }
            let dependencies = EngineDependencies(recorder: recorder, makeApple: { Apple("please send the report") },
                sttTransport: stt, groqCleanupTransport: HTTP(""), localCleanupTransport: HTTP(""),
                inserter: TextInserter(pasteboard: clipboard, postKeystroke: { pastes += 1 }),
                panelFactory: { Panel() }, requestMicrophoneAccess: { $0(true) },
                frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
            let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .captureOnly,
                                           dependencies: dependencies)
            let engine = DictationEngine(controller: controller)
            controller.onSessionNote = { notes.add($0) }
            var states: [DictateAppKit.DictationState] = []
            engine.onState = { states.append($0) }
            engine.start()
            if scenario == .headsetZeros {
                try await Task.sleep(nanoseconds: 100_000_000)               // ≈ 2 s of media at 20×
                engine.finish()
            }
            try await waitFor { FileManager.default.fileExists(atPath: paths.logURL.path) }
            let line = try String(contentsOf: paths.logURL, encoding: .utf8)
            let lines = notes.snapshot
            let start = lines.first { $0.contains("event=start") } ?? ""
            let session = start.components(separatedBy: "session=").last?.components(separatedBy: " ").first ?? "?"
            let end = lines.first { $0.contains("session=\(session) event=end") } ?? ""
            if scenario == .builtinDies {
                #expect(line.contains("outcome=error:mic_dead"))
                let bytes = Int(line.components(separatedBy: "bytes=").last?.components(separatedBy: " ").first ?? "") ?? 0
                #expect(bytes > 44)                                          // the real bytes, never 0
                #expect(!line.contains("duration=0.0s"))
                #expect(states.contains(.error(word: "no mic signal")))
                #expect(lines.contains { $0.contains("fail reason=mic_dead") })
                #expect(end.contains("outcome=error:mic_dead"))
                #expect(await stt.requests == 0 && pastes == 0)
            } else {
                #expect(line.contains("outcome=ok"))
                #expect(!lines.contains { $0.contains("fail reason=mic_dead") })
                #expect(end.contains("outcome=ok") && end.contains("speech_sections=") && !end.contains("capture_intervals=none"))
            }
            #expect(session.count == 8 && end.contains("recording_ms="))
        }
    }
}
