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

/// v1.27 B1: the first dictation after a pause ended `error:mic_dead` at 2.0 s with `bytes=44`
/// (2026-11-03 03:11:39, cc891096): the built-in's slow start was device-checked before it returned,
/// the unreadable read-back was reported as drift and the built-in written off, and the 2.0 s deadline
/// passed while the headset's start was still in flight. `builtin_start_slow` replays that trace.
/// No hardware, no network.
@Suite("V127FirstDictation", .serialized)
struct V127FirstDictationTests {
    private static func tone(seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
    }
    private func wav(seconds: Double) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v127-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        try WAVEncoder.encode(samples: Self.tone(seconds: seconds), sampleRate: 24_000, channels: 1).write(to: url)
        return (dir, url)
    }
    /// A hang detector (bounded): records a literal issue and throws when the event never comes.
    private func waitFor(_ event: String, seconds: Int = 20, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("missing event=\(event) after \(seconds)s")
        throw URLError(.timedOut)
    }
    private static func field(_ name: String, in line: String) -> String {
        line.components(separatedBy: " \(name)=").dropFirst().first?.components(separatedBy: " ").first ?? "none"
    }

    /// Stepped on the media clock (no wall-clock deadline): the recorder-level replay.
    private func stepped(_ scenario: WAVInjectedRecorder.Scenario, mediaSeconds: Double)
        throws -> (notes: [String], stats: AudioRecorder.CaptureStats, pcm: [Int16]) {
        let (dir, url) = try wav(seconds: 7)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: scenario)
        let notes = Lines()
        let lock = NSLock()
        var pcm: [Int16] = []
        recorder.note = { notes.add($0) }
        recorder.mediaLimit = mediaSeconds + 0.2
        recorder.onPCMChunk = { chunk in lock.withLock { pcm += chunk } }
        recorder.manualPacing = true
        try recorder.start()
        recorder.resetCapture()
        for _ in 0..<Int(mediaSeconds * 10 + 0.5) {
            recorder.step()
            if notes.snapshot.contains(where: { $0.hasPrefix("fail reason=") }) { break }
        }
        _ = recorder.stop()
        return (notes.snapshot, recorder.stats, lock.withLock { pcm })
    }

    /// RED on 55cb366: `fail reason=mic_dead … bytes=44 sources=builtin:drift,headset:starting` at 2.0 s.
    @Test func builtinStartSlowRecorderKeepsTheDictation() throws {
        let result = try stepped(.builtinStartSlow, mediaSeconds: 4)
        let fail = result.notes.first { $0.hasPrefix("fail reason=") } ?? "none"
        print("B1 LITERAL recorder fail=\(fail) carrier=\(result.stats.carrier) device_checks=\(result.notes.filter { $0.hasPrefix("bridge_device_check=") })")
        #expect(fail == "none")
        #expect(!result.notes.contains { $0.hasPrefix("bridge_builtin_lost=1") })
        #expect(result.stats.carrier.hasPrefix("builtin:"))
        #expect(result.stats.carrier.contains(",headset:"))
        #expect(result.stats.headsetCarriedMs >= 1_500)
    }

    /// The session-end line through the production controller (`outcome=` / `bytes=` / `carrier=`).
    @MainActor private func dictation(_ scenario: WAVInjectedRecorder.Scenario, mediaSeconds: Double) async throws -> (end: String, notes: [String]) {
        let (dir, url) = try wav(seconds: 7)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppPaths(home: dir.appendingPathComponent("home"))
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor("key") { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-v127-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: scenario)
        recorder.mediaLimit = mediaSeconds + 0.3
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
        engine.start()
        // Media time passes at 20×: wait for the recorder's media clock (not a level count) or an early end.
        let mediaTicks = Int(mediaSeconds * 10)
        try await waitFor("media_or_end") {
            notes.snapshot.contains { $0.contains("event=end") } || recorder.mediaMs >= mediaTicks * 100
        }
        engine.finish()
        try await waitFor("end") { notes.snapshot.contains { $0.contains("event=end") } }
        return (notes.snapshot.first { $0.contains("event=end") } ?? "", notes.snapshot)
    }

    @MainActor @Test func builtinStartSlowDictationPastes() async throws {
        let (end, _) = try await dictation(.builtinStartSlow, mediaSeconds: 3.5)
        let literal = "outcome=\(Self.field("outcome", in: end)) bytes=\(Self.field("bytes", in: end)) carrier=\(Self.field("carrier", in: end))"
        print("B1 LITERAL engine \(literal)")
        #expect(end.contains(" event=end outcome=ok "), "\(literal)")
        #expect(Self.field("carrier", in: end).hasPrefix("builtin:"), "\(literal)")
        #expect(Self.field("carrier", in: end).contains(",headset:"), "\(literal)")
    }

    // Positive controls: a REAL loss mid-dictation still fails exactly as on 55cb366.
    @MainActor @Test func builtinDriftsControlStillMicDead() async throws {
        let (end, notes) = try await dictation(.builtinDrifts, mediaSeconds: 3.5)
        let fail = notes.first { $0.hasPrefix("fail reason=") } ?? "none"
        print("B1 LITERAL control builtin_drifts outcome=\(Self.field("outcome", in: end)) \(fail)")
        #expect(end.contains(" event=end outcome=error:mic_dead "))
        #expect(notes.contains("bridge_device_check=drift from=154 fixed=0"))
        #expect(notes.contains { $0.hasPrefix("bridge_builtin_lost=1 reason=drift") })
        #expect(!notes.contains { $0.hasPrefix("builtin_rebuilt=") })
    }

    @MainActor @Test func builtinDiesControlStillMicDead() async throws {
        let (end, notes) = try await dictation(.builtinDies, mediaSeconds: 3.5)
        let fail = notes.first { $0.hasPrefix("fail reason=") } ?? "none"
        print("B1 LITERAL control builtin_dies outcome=\(Self.field("outcome", in: end)) \(fail)")
        #expect(end.contains(" event=end outcome=error:mic_dead "))
        #expect(fail.hasPrefix("fail reason=mic_dead health=stale_builtin"))
        #expect(!notes.contains { $0.hasPrefix("builtin_rebuilt=") })
    }

    // MARK: the same trace through the real `AudioRecorder` (fake units, real health clock, no hardware)

    /// The built-in AUHAL of cc891096: its device resolves at once, the unit's device property is
    /// unreadable until `start(epoch:)` returns `startBlocks` later; then 10 ms buffers flow.
    final class SlowBuiltin: BuiltinCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onDeviceLost: ((CaptureEpoch) -> Void)?
        let startBlocks: TimeInterval
        private let lock = NSLock()
        private var running: CaptureEpoch?
        private var timer: DispatchSourceTimer?
        private(set) var startBegan = false
        private(set) var starts = 0
        init(startBlocks: TimeInterval) { self.startBlocks = startBlocks }
        func start(epoch: CaptureEpoch) throws {
            lock.withLock { startBegan = true; starts += 1 }
            Thread.sleep(forTimeInterval: startBlocks)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "v127.fake.builtin"))
            // A real AUHAL's first input callback comes one IO cycle after `AudioOutputUnitStart` returns.
            timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
            timer.setEventHandler { [weak self] in
                guard let self, let epoch = self.lock.withLock({ self.running }) else { return }
                self.onFrames?([Float](repeating: 0.1, count: 240), ProcessInfo.processInfo.systemUptime - 0.01, epoch)
            }
            lock.withLock { running = epoch; self.timer = timer }
            timer.resume()
        }
        func stop() { lock.withLock { running = nil; timer?.cancel(); timer = nil } }
        func stop(epoch: CaptureEpoch) { if lock.withLock({ running === epoch }) { stop() } }
        var isDelivering: Bool { lock.withLock { running != nil } }
        var currentDeviceID: UInt32? { lock.withLock { running != nil ? 81 : nil } }
        var expectedDeviceID: UInt32? { 81 }
        var lastBufferTime: TimeInterval? { nil }
        let backend = "fake"
    }

    /// The headset client whose start is in flight until `startReturnsAt` (uptime), then 20 ms buffers flow.
    final class SlowHeadset: HeadsetCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)?
        var startReturnsAt: TimeInterval = 0
        private let lock = NSLock()
        private var epoch: CaptureEpoch?
        private var timer: DispatchSourceTimer?
        func start(deviceUID: String, epoch: CaptureEpoch) throws {
            let wait = startReturnsAt - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "v127.fake.headset"))
            timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
            timer.setEventHandler { [weak self] in
                guard let self, let epoch = self.lock.withLock({ self.epoch }) else { return }
                self.onFrames?([Float](repeating: 0.2, count: 480), ProcessInfo.processInfo.systemUptime - 0.02, epoch)
            }
            lock.withLock { self.epoch = epoch; self.timer = timer }
            onEvent?(.started(deviceUID: deviceUID, sampleRate: 16_000, channels: 1), epoch)
            timer.resume()
        }
        func stop() { lock.withLock { epoch = nil; timer?.cancel(); timer = nil } }
        func stop(epoch: CaptureEpoch) { if lock.withLock({ self.epoch === epoch }) { stop() } }
        var isRunning: Bool { lock.withLock { epoch != nil } }
        var lastCallbackTime: TimeInterval? { nil }
        var formatGeneration: Int { 1 }
        var counters: SourceCounters { SourceCounters() }
        let backend = "auhal"
    }

    static let route = CaptureRouteProbe(eligibility: { (.bluetooth, true) }, defaultInput: { 77 },
                                         uid: { _ in "58-18-62-21-1C-6A:input" }, defaultInputName: { "WH-1000XM6" })

    /// RED on 55cb366: `mic_dead` 2.0 s after the boundary while the headset's start is in flight.
    @Test func builtinStartSlowThroughTheRealRecorderKeepsTheDictation() async throws {
        let builtin = SlowBuiltin(startBlocks: 1.5)
        let headset = SlowHeadset()
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .auhal,
                                     broker: CaptureLeaseBroker(), route: Self.route)
        let failures = Lines()
        recorder.onCaptureFailure = { failures.add($0.note) }
        let t0 = ProcessInfo.processInfo.systemUptime
        headset.startReturnsAt = t0 + 2.2
        let start = Task { try await recorder.startAsync(device: .default) }
        try await waitFor("builtin_start") { builtin.startBegan }
        recorder.resetCapture()                               // the second tap: the health clock runs from here
        try await waitFor("media_4s", seconds: 30) { ProcessInfo.processInfo.systemUptime - t0 >= 4.0 || !failures.snapshot.isEmpty }
        _ = try? await start.value
        _ = recorder.stop()
        let fail = failures.snapshot.first ?? "none"
        let stats = recorder.stats
        print("B1 LITERAL real_recorder fail=\(fail) carrier=\(stats.carrier) headset_carried_ms=\(stats.headsetCarriedMs) builtin_starts=\(builtin.starts)")
        #expect(fail == "none")
        #expect(stats.carrier.hasPrefix("builtin:") && stats.carrier.contains(",headset:"))
        _ = await recorder.awaitRelease()
    }
}
