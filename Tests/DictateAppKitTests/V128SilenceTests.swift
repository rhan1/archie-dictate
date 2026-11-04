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
    /// v1.28 FR5: (request index, the request's 16 kHz samples) → the whole `verbose_json` payload, when set.
    let verbose: (@Sendable (Int, [Int16]) -> [String: Any])?
    private var sttRequests = 0
    init(stt: @escaping @Sendable (Int, Int) -> String, cleanup: Cleanup,
         verbose: (@Sendable (Int, [Int16]) -> [String: Any])? = nil) {
        self.stt = stt; self.cleanup = cleanup; self.verbose = verbose
    }
    static func samples(_ body: Data) -> [Int16] {
        guard let riff = body.range(of: Data("RIFF".utf8))?.lowerBound else { return [] }
        let size = (0..<4).reduce(0) { $0 | Int(body[riff + 40 + $1]) << (8 * $1) }
        let start = riff + 44
        return stride(from: start, to: min(body.count - 1, start + size), by: 2).map {
            Int16(bitPattern: UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8)
        }
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let payload: [String: Any]
        if url.path.contains("transcriptions") {
            if let verbose { payload = verbose(sttRequests, Self.samples(request.httpBody ?? Data())) }
            else { payload = ["text": stt(sttRequests, request.httpBody?.count ?? 0)] }
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
    struct Run { var end: String; var pasted: String?; var pill: String; var timeline: String; var log: String; var trace = "" }

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
                                    stt: @escaping @Sendable (Int, Int) -> String, cleanup: FR2HTTP.Cleanup,
                                    trace: Bool = false,
                                    verbose: (@Sendable (Int, [Int16]) -> [String: Any])? = nil) async throws -> Run {
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
        let http = FR2HTTP(stt: stt, cleanup: cleanup, verbose: verbose)
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { Apple() },
            sttTransport: http, groqCleanupTransport: http, localCleanupTransport: http, inserter: inserter,
            panelFactory: { Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate,
                                       dependencies: dependencies, stt: .groqChunked)
        let notes = Box<[String]>([])
        controller.onSessionNote = { line in notes.update { $0.append(line) } }
        let engine = DictationEngine(controller: controller)
        if trace {
            let suite = "dictate-v128-fr3c-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: TranscriptTrace.key)
            engine.transcriptTrace(defaults: defaults)
        }
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
        let traceDir = TranscriptTrace.directory(logURL: paths.logURL)
        let traceText = ((try? FileManager.default.contentsOfDirectory(at: traceDir, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        return Run(end: notes.get.first { $0.contains("event=end") } ?? "", pasted: pasted.get, pill: pill.get,
                   timeline: controller.lastTimelineLine ?? "", log: log, trace: traceText)
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

    /// v1.28 FR3-C (Raza's step 4, 02:23:23, trace 73757a51.txt): raw `Send the invoice to Limpar today.` + final chunk
    /// `Yes.` → `cleaned=Send the invoice to Limpar today.` → "Yes." lost. The stub cleaner drops it the same way.
    /// RED on 0faa887: pasted without "Yes.", no `cleaner_in=` in the trace. GREEN: "Yes." restored, `cleaner_in=` traced.
    @MainActor @Test func sentenceFinalAnswerIsNeverDropped() async throws {
        let r = try await dictate(samples: Self.toneDictation(peak: 0.25), scenario: .plain, mediaSeconds: 4.2,
                                  stt: { _, bytes in bytes > 40_000 ? "Send the invoice to Limpar today. Yes." : "" },
                                  cleanup: .clean("Send the invoice to Limpar today."), trace: true)
        let cleanerIn = r.trace.split(separator: "\n").filter { $0.hasPrefix("cleaner_in=") }.map(String.init)
        print("FR3-C LITERAL outcome=\(Self.field("outcome", r.end)) pasted=\"\(r.pasted ?? "")\" trace_cleaner_in=\(cleanerIn)")
        #expect(r.pasted == "Send the invoice to Limpar today. Yes.")
        #expect(cleanerIn.contains("cleaner_in=Send the invoice to Limpar today. Yes."))
    }

    // MARK: v1.28 FR5 — Whisper's own confidence

    /// 14.5 s of built-in room noise (≈ −46 dBFS, as `roomNoise` without the headset's zero stretch), 3.0 s of speech
    /// (220 Hz at 0.25 peak), 0.4 s room: Raza's re-test 1 (2026-11-05 06:45:43, 17.9 s, `carrier=builtin:0-17802`).
    static func silentThenSpeech() -> [Int16] {
        let room = (0..<Int(17.9 * 24_000)).map { i -> Int16 in
            let rms = pow(10, (-46 + 3.6 * gauss(i / 1_200, salt: 3)) / 20)
            return Int16(max(-32_767, min(32_767, (gauss(i, salt: 11) * rms * 32_768).rounded())))
        }
        let toneStart = Int(14.5 * 24_000), toneEnd = Int(17.5 * 24_000)
        return room.enumerated().map { i, sample in
            guard i >= toneStart && i < toneEnd else { return sample }
            return Int16(0.25 * 32_767 * sin(Double(i - toneStart) * 2 * .pi * 220 / 24_000))
        }
    }

    /// The stub plays Whisper as trace 97ee30ab.txt recorded it: the first noise-only request `Positives`, the second
    /// empty, later noise-only requests the invented `Let's see if you can start recording this recording.`
    /// (p=0.82 lp=-1.3, FR5-C); a request holding the speech returns the invented sentence over its noise lead (when
    /// ≥ 0.5 s) and the real sentences over the speech (p=0.02 lp=-0.25). Segment times come from the request's audio.
    static func whisper0645(_ index: Int, _ samples: [Int16]) -> [String: Any] {
        let invented = "Let's see if you can start recording this recording."
        let duration = Double(samples.count) / 16_000
        func segment(_ start: Double, _ end: Double, _ text: String, _ p: Double, _ lp: Double) -> [String: Any] {
            ["start": start, "end": end, "text": " " + text, "no_speech_prob": p, "avg_logprob": lp, "compression_ratio": 1.1]
        }
        var segments: [[String: Any]] = []
        if let first = samples.firstIndex(where: { abs(Int($0)) > 4_000 }) {
            let lead = Double(first) / 16_000
            if lead >= 0.5 { segments.append(segment(0, lead, invented, 0.82, -1.3)) }
            segments.append(segment(lead, lead + 1.1, "Cold start one.", 0.02, -0.25))
            segments.append(segment(lead + 1.1, duration, "This should begin on the first tap.", 0.02, -0.25))
        } else if index == 0 {
            segments.append(segment(0, duration, "Positives", 0.7, -1.2))
        } else if index > 1 {
            segments.append(segment(0, duration, invented, 0.82, -1.3))
        }
        let text = segments.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return ["text": text, "segments": segments]
    }

    /// RED on 3c6aad8: the invented sentence is pasted with the real one. GREEN: only "Cold start one. This should
    /// begin on the first tap." The cleaner is offline (strong audio → the transcript is pasted as recognised), so the
    /// paste shows exactly what recognition kept.
    @MainActor @Test func inventedSentenceOverRoomNoiseIsNeverPasted() async throws {
        let r = try await dictate(samples: Self.silentThenSpeech(), scenario: .plain, mediaSeconds: 17.9,
                                  stt: { _, _ in "" }, cleanup: .offline, trace: true, verbose: Self.whisper0645)
        let segmentLines = r.trace.split(separator: "\n").filter { $0.contains("segments=") }.count
        print("FR5 LITERAL controller_0645 \(Self.literal(r)) stt_dropped_segment_conf=\(Self.field("stt_dropped_segment_conf", r.timeline)) trace_segment_lines=\(segmentLines)")
        print("FR5 TRACE \(r.trace.split(separator: "\n").filter { $0.hasPrefix("chunk=") }.joined(separator: " | "))")
        #expect(r.pasted == "Cold start one. This should begin on the first tap.")
    }
}
