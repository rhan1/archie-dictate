import AppKit
import Testing
import DictateCore
@testable import DictateAppKit

private final class VoiceStopPanel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) {}
    func hide() {}
    func push(level: Double) {}
}

private final class VoiceStopApple: EngineAppleSession, @unchecked Sendable {
    let text: String
    init(_ text: String) { self.text = text }
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { text }
    func cancel() {}
}

private actor VoiceStopHTTP: HTTPTransport {
    let text: String
    init(_ text: String) { self.text = text }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let payload: [String: Any] = request.url!.path.contains("transcriptions")
            ? ["text": text]
            : ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class VoiceStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

/// v18 / Archie v55 X1 (b): a TRAILING "stop dictation" / "archie stop" /
/// "end dictation" that stands as its own sentence at the end of the final
/// transcript ends the dictation and is not pasted; the same words anywhere
/// else (or ending a longer sentence) are dictated text and are left alone.
/// The fixture is the injected-WAV engine of InjectedEngineTests: the host
/// facade, the real rig sink and WAV recorder, no capture hardware, no network.
@Suite("V18VoiceStopTests", .serialized) @MainActor
struct V18VoiceStopTests {
    struct Outcome {
        var pasted: String?
        var endLine: String
        var secondChords: Int
        var voiceStopNotes: Int
    }

    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    /// Dictates the injected fixture whose transcript is `heard`. When the
    /// dictation is not ended by the transcript itself, the second chord (the
    /// finish gesture) ends it, like Raza's second Option tap.
    private func dictate(_ heard: String) async throws -> Outcome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v18-voicestop-\(UUID().uuidString)")
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
        let keys = KeyStore(reader: { _ in "fixture-key" })
        keys.prefetch(services: ["groq-api"])
        _ = try await waitFor(12) { keys.key(for: "groq-api") != nil }
        let pb = NSPasteboard(name: .init("dictate-v18-voicestop-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let http = VoiceStopHTTP(heard)
        let deps = EngineDependencies(recorder: wave, makeApple: { VoiceStopApple(heard) },
            sttTransport: http, groqCleanupTransport: http, localCleanupTransport: http,
            inserter: TextInserter(pasteboard: pb, postKeystroke: {}, axReader: { [] }),
            panelFactory: { VoiceStopPanel() }, requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.fixture") }, manageMedia: false)
        let controller = AppController(keyStore: keys, paths: paths, surface: .none, mode: .dictate,
                                       dependencies: deps, injectedAudioURL: wav)
        let engine = DictationEngine(controller: controller)
        controller.configureEngine()
        defer { engine.cancel() }
        var ends: [String] = []
        var started = false
        let voiceStop = VoiceStopCounter()
        controller.onSessionNote = {
            if $0.contains("event=start") { started = true }
            if $0.contains("event=end") { ends.append($0) }
        }
        AppController.setNoteSink { if $0.contains("voice_stop=1") { voiceStop.bump() } }
        defer { AppController.setNoteSink(nil) }
        let rig = root.appendingPathComponent("rig")
        try FileManager.default.createDirectory(at: rig, withIntermediateDirectories: true)
        #expect(engine.enableRig(launchEnvironment: ["DICTATE_RIG": "1", "DICTATE_RIG_DIR": rig.path]) {
            engine.handle($0 == .tap ? .tap : .doubleTap)
        })
        let trigger = rig.appendingPathComponent("trigger")
        func chord() {
            #expect(FileManager.default.createFile(atPath: trigger.path, contents: Data("chord selftest\n".utf8),
                                                   attributes: [.posixPermissions: 0o600]))
        }
        chord()
        _ = try await waitFor(12) { wave.isRunning && started && !controller.micStartPending }
        for _ in 0..<90 {
            wave.step()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        var secondChords = 0
        // Give a voice stop its own chance to end the dictation first.
        var ended = try await waitFor(3) { !ends.isEmpty }
        if !ended {
            secondChords = 1
            chord()
            ended = try await waitFor(12) { !ends.isEmpty }
        }
        #expect(ended)
        let output = rig.appendingPathComponent("out/selftest.txt")
        return Outcome(pasted: try? String(contentsOf: output, encoding: .utf8), endLine: ends.first ?? "-",
                       secondChords: secondChords, voiceStopNotes: voiceStop.value)
    }

    private func chars(_ line: String) -> Int {
        line.split(separator: " ").first { $0.hasPrefix("chars=") }.flatMap { Int($0.dropFirst(6)) } ?? -1
    }

    @Test(.timeLimit(.minutes(2))) func trailingStopPhraseEndsTheDictationAndIsNotPasted() async throws {
        let heard = "Please send the report. Stop dictation."
        let o = try await dictate(heard)
        let expected = "Please send the report."
        let good = o.pasted == expected && o.secondChords == 0
        print("X1b \(good ? "GREEN" : "RED") pasted_chars=\(o.pasted?.count ?? -1) log_chars=\(chars(o.endLine)) phrase_pasted=\(o.pasted?.lowercased().contains("stop dictation") == true ? 1 : 0) "
              + "voice_stop_notes=\(o.voiceStopNotes) second_chords=\(o.secondChords)")
        #expect(o.pasted == expected)
        #expect(chars(o.endLine) == expected.count)
        #expect(o.endLine.contains("outcome=ok"))
        #expect(o.secondChords == 0, "the phrase itself ends the dictation")
    }

    @Test(.timeLimit(.minutes(2))) func stopPhraseInsideOrEndingARealSentenceIsDictatedText() async throws {
        let cases = ["I told him to stop dictation yesterday.",
                     "He said stop dictation.",
                     "Please do not stop dictation now, okay?"]
        var report: [String] = []
        for heard in cases {
            let o = try await dictate(heard)
            report.append("pasted=\(o.pasted == heard ? "verbatim" : "CHANGED") second_chords=\(o.secondChords) voice_stop_notes=\(o.voiceStopNotes)")
            #expect(o.pasted == heard, "dictated words must reach the paste untouched")
            #expect(o.secondChords == 1, "only the finish gesture ends a dictation that merely mentions the phrase")
            #expect(o.voiceStopNotes == 0)
        }
        print("X1b CONTROL mentioned_not_commanded \(report.joined(separator: " | "))")
    }
}
