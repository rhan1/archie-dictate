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
/// Whisper as modelled for B2 (prompt echo on near-silence), returning a sentence per request: speech → its
/// sentence; short non-speech → "Dictate." when prompted, "" when not. Cleanup echoes its input.
private actor EchoHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody ?? Data()
        let payload: [String: Any]
        if request.url!.path.contains("transcriptions") {
            let text = String(decoding: body, as: UTF8.self)
            let prompt: String = {
                guard let r = text.range(of: "name=\"prompt\"\r\n\r\n") else { return "" }
                let rest = text[r.upperBound...]
                return String(rest[..<(rest.range(of: "\r\n--")?.lowerBound ?? rest.endIndex)])
            }()
            let bytes = body.count
            payload = ["text": bytes > 40_000 ? "Please send the report to Archie today." : (prompt.isEmpty ? "" : "Dictate.")]
        } else {
            payload = ["choices": [["finish_reason": "stop", "message": ["content": ""]]]]
        }
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

/// v1.27 B3 (opt-in local transcript trace) and C (plain dictation unchanged), through the production
/// controller with an injected WAV (`DICTATE_INJECT_SCENARIO=plain`). No hardware, no network.
@Suite("V127TraceAndParity", .serialized)
struct V127TraceAndParityTests {
    /// 0.3 s room, 3.4 s of speech-level tone, 0.5 s room: an ordinary dictation.
    static func samples() -> [Int16] {
        func noise(_ n: Int) -> [Int16] { (0..<n).map { Int16(($0 &* 7919) % 101 - 50) } }
        let tone = (0..<Int(3.4 * 24_000)).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
        return noise(7_200) + tone + noise(12_000)
    }
    private func waitFor(_ event: String, seconds: Int = 20, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("missing event=\(event) after \(seconds)s")
        throw URLError(.timedOut)
    }

    struct Outcome { let end: String; let transcript: String; let traceFiles: [URL]; let logText: String }

    @MainActor private func dictate(traceDefaults: UserDefaults?) async throws -> Outcome {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v127-trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plain.wav")
        try WAVEncoder.encode(samples: Self.samples(), sampleRate: 24_000, channels: 1).write(to: url)
        let paths = AppPaths(home: dir.appendingPathComponent("home"))
        let keys = KeyStore(reader: { _ in "fixture" })
        keys.prefetch(services: ["groq-api"])
        try await waitFor("key") { keys.key(for: "groq-api") != nil }
        let clipboard = NSPasteboard(name: .init("dictate-v127-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let scenario = WAVInjectedRecorder.scenario(environment: ["DICTATE_INJECT_SCENARIO": "plain"])
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: scenario)
        recorder.mediaLimit = 4.4
        let notes = Lines()
        recorder.note = { notes.add($0) }
        let dependencies = EngineDependencies(recorder: recorder, makeApple: { Apple() },
            sttTransport: EchoHTTP(), groqCleanupTransport: EchoHTTP(), localCleanupTransport: EchoHTTP(),
            inserter: TextInserter(pasteboard: clipboard, postKeystroke: {}),
            panelFactory: { Panel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.host") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .captureOnly,
                                       dependencies: dependencies)
        controller.onSessionNote = { notes.add($0) }
        let engine = DictationEngine(controller: controller)
        if let traceDefaults { engine.transcriptTrace(defaults: traceDefaults) }
        let transcripts = Lines()
        engine.onTranscript = { text, _ in transcripts.add(text) }
        engine.start()
        try await waitFor("media_4.2s") { recorder.mediaMs >= 4_200 }
        engine.finish()
        try await waitFor("end") { notes.snapshot.contains { $0.contains("event=end") } }
        let traceDir = TranscriptTrace.directory(logURL: paths.logURL)
        let files = (try? FileManager.default.contentsOfDirectory(at: traceDir, includingPropertiesForKeys: nil)) ?? []
        // Copy what the test inspects before the temporary home is removed.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v127-trace-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        var kept: [URL] = []
        for file in files {
            let target = keep.appendingPathComponent(file.lastPathComponent)
            let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1
            try FileManager.default.copyItem(at: file, to: target)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            kept.append(target)
        }
        let log = (try? String(contentsOf: paths.logURL, encoding: .utf8)) ?? ""
        return Outcome(end: notes.snapshot.first { $0.contains("event=end") } ?? "", transcript: transcripts.snapshot.last ?? "",
                       traceFiles: kept, logText: log + notes.snapshot.joined(separator: "\n"))
    }

    private static func suite(_ name: String, trace: Bool?) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        if let trace { defaults.set(trace, forKey: TranscriptTrace.key) }
        return defaults
    }

    /// B3: absent/false → nothing written; true → one 0600 file of chunk/cleaned/pasted lines. dictate.log never has text.
    @MainActor @Test func transcriptTraceIsOffByDefaultAndLocalWhenOn() async throws {
        let offName = "dictate-v127-trace-off-\(UUID().uuidString)", onName = "dictate-v127-trace-on-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: offName); UserDefaults().removePersistentDomain(forName: onName) }
        let off = try await dictate(traceDefaults: Self.suite(offName, trace: nil))
        let offText = off.logText.contains("Please send the report") || off.logText.contains("Dictate.")
        print("B3 LITERAL OFF trace_files=\(off.traceFiles.count) log_has_text=\(offText ? 1 : 0) transcript=\"\(off.transcript)\"")
        #expect(off.traceFiles.isEmpty)
        #expect(!off.logText.contains("transcript_trace=on"))
        #expect(!offText)
        #expect(!off.transcript.isEmpty)

        let on = try await dictate(traceDefaults: Self.suite(onName, trace: true))
        let file = try #require(on.traceFiles.first)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1
        let onText = on.logText.contains("Please send the report") || on.logText.contains("Dictate.")
        print("B3 LITERAL ON trace_files=\(on.traceFiles.count) lines=\(lines.count) mode=\(String(mode, radix: 8)) log_has_text=\(onText ? 1 : 0) file=\(file.lastPathComponent)")
        for line in lines { print("B3 LITERAL ON line \(line)") }
        #expect(on.traceFiles.count == 1 && mode == 0o600)
        #expect(lines.contains { $0.hasPrefix("chunk=0 final=") && $0.contains(" prompt=full raw=Please send the report to Archie today.") })
        #expect(lines.contains { $0.hasPrefix("pasted=") })
        #expect(on.logText.contains("transcript_trace=on") && !onText)
        let session = on.end.components(separatedBy: "session=").dropFirst().first?.components(separatedBy: " ").first ?? "?"
        #expect(file.lastPathComponent == "\(session).txt")
        for f in off.traceFiles + on.traceFiles { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
    }

    /// C: an ordinary dictation is unchanged (outcome and delivered text), whatever the trace setting.
    @MainActor @Test func plainDictationTextParity() async throws {
        let run = try await dictate(traceDefaults: nil)
        let outcome = run.end.components(separatedBy: " outcome=").dropFirst().first?.components(separatedBy: " ").first ?? "none"
        print("C LITERAL NORMAL outcome=\(outcome) text=\"\(run.transcript)\"")
        #expect(outcome == "ok")
        #expect(run.transcript == "Please send the report to Archie today.")
    }
}
