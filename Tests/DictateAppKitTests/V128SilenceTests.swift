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
    func finish() async throws -> String { "" }
    func cancel() {}
}
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    var get: T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
}

/// Whisper and the cleaner as needed per case. In-memory only; never URLSession.
private actor FR2HTTP: HTTPTransport {
    enum Cleanup { case reject, clean(String), offline }
    let stt: @Sendable (Int, Int) -> String          // (request index, body bytes) → text
    let cleanup: Cleanup
    private var sttRequests = 0
    init(stt: @escaping @Sendable (Int, Int) -> String, cleanup: Cleanup) { self.stt = stt; self.cleanup = cleanup }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let payload: [String: Any]
        if url.path.contains("transcriptions") {
            payload = ["text": stt(sttRequests, request.httpBody?.count ?? 0)]
            sttRequests += 1
        } else if url.path.hasSuffix("/models") {
            payload = ["data": []]
        } else {
            switch cleanup {
            case .reject: payload = ["choices": [["finish_reason": "stop", "message": ["content": "x"]]]]   // ratio → rejected
            case .clean(let text): payload = ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
            case .offline: throw URLError(.notConnectedToInternet)
            }
        }
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
}

/// v1.28 FR2: silence must never paste invented words. 2026-11-04 00:43 (19f69203, Archie 62.4.1 / Dictate 1.27):
/// Raza silent for 22 s on HFP → headset near-zeros, built-in room noise (`raw_rms_p50_dbfs=-46.1 p90=-41.4`),
/// 5 chunks of prompt echoes, cleaner `mid_rejected_ratio` → the raw echoes were pasted. No hardware, no network.
@Suite("V128Silence", .serialized)
struct V128SilenceTests {
    struct Run { var end: String; var pasted: String?; var pill: String; var timeline: String; var log: String }

    static let echoes = ["Dives by T. Dictate.", "Dives by T T T. Dictate.", "Dives by T T T.", "Thank you.",
                         "The floor. Thank you.", "Thank you.", "Dictate."]

    /// Deterministic standard-normal-ish value for `index` (sum of three hashed uniforms).
    static func gauss(_ index: Int, salt: UInt64) -> Double {
        func u(_ k: UInt64) -> Double {
            var x = (UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15) ^ (k &* 0xBF58_476D_1CE4_E5B9) ^ salt
            x ^= x >> 31; x &*= 0x94D0_49BB_1331_11EB; x ^= x >> 29
            return Double(x % 1_000_000) / 1_000_000
        }
        return (u(1) + u(2) + u(3) - 1.5) * 2          // mean 0, sd 1
    }

    /// The built-in's room noise as 19f69203 measured it: 50 ms windows at −46 dBFS ± 3.6 dB (p10 ≈ −50.6,
    /// p90 ≈ −41.4), sample peaks ≈ −30. From 3.235 s to 5.638 s the transcribed audio was the headset's
    /// near-zeros (`carrier=…,headset:3235-5638,…`, −89 dBFS): replayed here as what the transcriber received.
    static func roomNoise(seconds: Double) -> [Int16] {
        let n = Int(seconds * 24_000)
        return (0..<n).map { i -> Int16 in
            let t = Double(i) / 24_000
            if t >= 3.235 && t < 5.638 { return Int16((gauss(i, salt: 7) * 1.2).rounded()) }    // ≈ −89 dBFS
            let window = i / 1_200
            let rms = pow(10, (-46 + 3.6 * gauss(window, salt: 3)) / 20)
            return Int16(max(-32_767, min(32_767, (gauss(i, salt: 11) * rms * 32_768).rounded())))
        }
    }
    /// 0.3 s room, 3.4 s tone at `peak` (linear), 0.5 s room.
    static func toneDictation(peak: Double) -> [Int16] {
        func room(_ n: Int) -> [Int16] { (0..<n).map { Int16(($0 &* 7919) % 101 - 50) } }
        let tone = (0..<Int(3.4 * 24_000)).map { Int16(peak * 32_767 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
        return room(7_200) + tone + room(12_000)
    }

    private func waitFor(_ event: String, seconds: Int = 30, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("missing event=\(event) after \(seconds)s")
        throw URLError(.timedOut)
    }

    @MainActor private func dictate(samples: [Int16], scenario: WAVInjectedRecorder.Scenario, mediaSeconds: Double,
                                    stt: @escaping @Sendable (Int, Int) -> String, cleanup: FR2HTTP.Cleanup) async throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v128-fr2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fr2-\(UUID().uuidString.prefix(8)).wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1).write(to: url)
        let paths = AppPaths(home: dir.appendingPathComponent("home"))
        let keys = KeyStore(reader: { $0 == "groq-api" ? "fixture" : "" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor("key") { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-v128-fr2-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let confirmed = Box<[String]?>([])
        let pasted = Box<String?>(nil)
        let inserter = TextInserter(pasteboard: clipboard, postKeystroke: {
            let text = clipboard.string(forType: .string)
            pasted.set(text)
            confirmed.set(text.map { [$0] } ?? [])
        }, axReader: { confirmed.get })
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: scenario)
        recorder.mediaLimit = mediaSeconds + 0.3
        recorder.note = { _ in }
        let http = FR2HTTP(stt: stt, cleanup: cleanup)
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { Apple() },
            sttTransport: http, groqCleanupTransport: http, localCleanupTransport: http, inserter: inserter,
            panelFactory: { Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate,
                                       dependencies: dependencies, stt: .groqChunked)
        let notes = Box<[String]>([])
        controller.onSessionNote = { line in notes.update { $0.append(line) } }
        let engine = DictationEngine(controller: controller)
        let pill = Box<String>("none")
        engine.onState = { state in
            switch state {
            case .pasted: pill.set("pasted")
            case .error(let word): pill.set("word=\(word)")
            case .held(let preview): pill.set("held_preview=\(preview.count)")
            default: break
            }
        }
        engine.start()
        try await waitFor("media") { recorder.mediaMs >= Int(mediaSeconds * 1000) - 100 }
        engine.finish()
        try await waitFor("end") { notes.get.contains { $0.contains("event=end") } }
        try await waitFor("timeline") { controller.lastTimelineLine != nil }
        try? await Task.sleep(nanoseconds: 100_000_000)       // the pill's outcome lands on the main queue
        let log = (try? String(contentsOf: paths.logURL, encoding: .utf8)) ?? ""
        return Run(end: notes.get.first { $0.contains("event=end") } ?? "", pasted: pasted.get, pill: pill.get,
                   timeline: controller.lastTimelineLine ?? "", log: log)
    }

    static func field(_ name: String, _ line: String) -> String {
        line.components(separatedBy: " \(name)=").dropFirst().first?.components(separatedBy: " ").first ?? "-"
    }
    static func literal(_ r: Run) -> String {
        "outcome=\(field("outcome", r.end)) chars=\(field("chars", r.end)) pill=\(r.pill)"
            + " pasted=\"\(r.pasted ?? "")\" stt_dropped_silent_chunk=\(field("stt_dropped_silent_chunk", r.timeline))"
            + " speech_sections=\(field("speech_sections", r.end)) cleanup_mode=\(field("cleanup_mode", r.timeline))"
            + " fallback_reason=\(field("fallback_reason", r.timeline)) chunks=\(field("chunks", r.timeline))"
    }

    /// RED on a3a1a11: the echoes are pasted (`outcome=ok`, pill "raw"). GREEN: `held:no_speech`, nothing pasted.
    @MainActor @Test func silentHeadsetRoomNoiseNeverPastesInventedWords() async throws {
        let r = try await dictate(samples: Self.roomNoise(seconds: 22.5), scenario: .silentHeadsetRoomnoise, mediaSeconds: 22,
                                  stt: { index, _ in Self.echoes[index % Self.echoes.count] }, cleanup: .reject)
        print("FR2 LITERAL silent_headset_roomnoise \(Self.literal(r))")
        #expect(Self.field("outcome", r.end) == "held:no_speech")
        #expect(r.pasted == nil)
        #expect(r.pill == "word=no speech")
    }

    /// Control: quiet but real speech (−30 dBFS peak) with the cleaner available → the cleaned text is pasted.
    @MainActor @Test func controlQuietRealSpeechPastesCleanedText() async throws {
        let r = try await dictate(samples: Self.toneDictation(peak: 0.0316), scenario: .plain, mediaSeconds: 4.2,
                                  stt: { _, bytes in bytes > 40_000 ? "please send the report to archie today" : "" },
                                  cleanup: .clean("Please send the report to Archie today."))
        print("FR2 CONTROL quiet_real_cleaner_available \(Self.literal(r))")
        #expect(Self.field("outcome", r.end) == "ok")
        #expect(r.pasted == "Please send the report to Archie today.")
    }

    /// FR2-B's STRONG branch: real speech, the cleaner rejects (ratio) → the raw transcript is still pasted (pill "raw").
    @MainActor @Test func strongAudioCleanerRejectionStillPastesRaw() async throws {
        let r = try await dictate(samples: Self.toneDictation(peak: 0.25), scenario: .plain, mediaSeconds: 4.2,
                                  stt: { _, bytes in bytes > 40_000 ? "please send the report to archie today" : "" },
                                  cleanup: .reject)
        print("FR2 LITERAL strong_audio_cleaner_rejected \(Self.literal(r))")
        #expect(Self.field("outcome", r.end) == "ok")
        #expect(r.pasted == "please send the report to archie today")
        #expect(r.pill == "word=raw")
    }

    /// Control: strong speech, cleaner unreachable → the raw transcript is pasted as today (pill "raw").
    @MainActor @Test func controlCleanerOfflineStrongAudioPastesRaw() async throws {
        let r = try await dictate(samples: Self.toneDictation(peak: 0.25), scenario: .plain, mediaSeconds: 4.2,
                                  stt: { _, bytes in bytes > 40_000 ? "please send the report to archie today" : "" },
                                  cleanup: .offline)
        print("FR2 CONTROL cleaner_offline_strong_audio \(Self.literal(r))")
        #expect(Self.field("outcome", r.end) == "ok")
        #expect(r.pasted == "please send the report to archie today")
        #expect(r.pill == "word=raw")
    }
}
