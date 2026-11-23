import AppKit
import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

private final class A62819Panel: EnginePanelDriving {
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    var isOnScreen = false
    var frame = NSRect.zero
    func show(_ mode: PillPanel.Mode, held: Bool, status: String?) {}
    func hide() {}
    func push(level: Double) {}
}

private final class A62819Apple: EngineAppleSession, @unchecked Sendable {
    func start() async throws {}
    func append(_ samples: [Int16]) {}
    func finish() async throws -> String { "" }
    func cancel() {}
}

private final class A62819LockedList<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) { lock.withLock { items.append(item) } }
    var all: [Element] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
}

private struct A62819DictationFakeLocal: LocalChunkSTT {
    var modelID: String { "fake-shadow-local" }
    func transcribe(pcm16k: [Int16]) async throws -> String { "something else entirely" }
}

/// Deterministic cloud HTTP fake: STT answers `"Chunk <tag> heard."` derived from the uploaded
/// audio bytes so concurrent chunk scheduling cannot reorder text; cleanup echoes `<dictation>`.
private actor A62819DictationCloudHTTP: HTTPTransport {
    private(set) var groq = 0
    private(set) var scribe = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url == ScribeClient.endpoint {
            scribe += 1
            let tag = Self.audioTag(from: request.httpBody) ?? scribe
            return (try JSONSerialization.data(withJSONObject: ["text": "Chunk \(tag) heard."]),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url == TranscriptionClient.groqEndpoint {
            groq += 1
            let tag = Self.audioTag(from: request.httpBody) ?? groq
            return (try JSONSerialization.data(withJSONObject: ["text": "Chunk \(tag) heard."]),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.path.contains("chat/completions") {
            let content = Self.echoDictation(from: request.httpBody)
            let payload: [String: Any] = [
                "choices": [["finish_reason": "stop", "message": ["content": content]]],
            ]
            return (try JSONSerialization.data(withJSONObject: payload),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private static func audioTag(from body: Data?) -> Int? {
        guard let body else { return nil }
        let marker = Data("name=\"file\"".utf8)
        guard let nameRange = body.range(of: marker),
              let headerEnd = body.range(of: Data("\r\n\r\n".utf8), in: nameRange.upperBound..<body.endIndex) else {
            return nil
        }
        let payloadStart = headerEnd.upperBound
        let payloadEnd = body.range(of: Data("\r\n--".utf8), in: payloadStart..<body.endIndex)?.lowerBound ?? body.endIndex
        var hash: UInt32 = 2_166_136_261
        for byte in body[payloadStart..<payloadEnd] {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return Int(hash % 10_000)
    }

    private static func echoDictation(from body: Data?) -> String {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: String]],
              let content = messages.last?["content"] else {
            return ""
        }
        if let open = content.range(of: "<dictation>", options: .backwards),
           let close = content.range(of: "</dictation>", range: open.upperBound..<content.endIndex) {
            return String(content[open.upperBound..<close.lowerBound])
        }
        return content
    }
}

/// archie-62819: ⌥⌥ dictation shadow engine (`LocalSTTShadow`, path=dictation) on recorded fixtures.
/// Side-by-side local STT never changes pasted text or cloud STT request count.
@Suite("A62819DictationShadowTests", .serialized) @MainActor
struct A62819DictationShadowTests {
    private struct RunResult {
        let outcome: String
        let text: String
        let cloudRequests: Int
        let shadowLines: [String]
    }

    private static var fixturesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/dictate/tools/fixtures/voice")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("Timed out waiting for injected dictation shadow run")
        throw URLError(.timedOut)
    }

    private func runDictation(wav: URL, samples: [Int16], mic: String, withShadow: Bool) async throws -> RunResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictate-a62819-shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(home: root.appendingPathComponent("home"))
        let wave = WAVInjectedRecorder(url: wav, scenario: .plain)
        wave.manualPacing = true
        wave.note = { _ in }
        let recorder: EngineRecorder = wave

        let keys = KeyStore(reader: { _ in "fixture-key" })
        keys.prefetch(services: ["groq-api", "elevenlabs-api"])
        try await waitFor { keys.key(for: "groq-api") != nil && keys.key(for: "elevenlabs-api") != nil }

        let pb = NSPasteboard(name: .init("dictate-a62819-shadow-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        let http = A62819DictationCloudHTTP()
        let deps = EngineDependencies(
            recorder: recorder,
            makeApple: { A62819Apple() },
            sttTransport: http,
            groqCleanupTransport: http,
            localCleanupTransport: http,
            inserter: TextInserter(pasteboard: pb, postKeystroke: {}, axReader: { [] }),
            panelFactory: { A62819Panel() },
            requestMicrophoneAccess: { $0(true) },
            frontmostTarget: { InsertionTarget(pid: 1, bundleID: "test.fixture") },
            manageMedia: false
        )

        let controller = AppController(
            keyStore: keys,
            paths: paths,
            surface: .none,
            mode: .dictate,
            dependencies: deps,
            injectedAudioURL: wav
        )
        let engine = DictationEngine(controller: controller)
        let shadowLogs = A62819LockedList<String>()
        if withShadow {
            engine.localSTTShadow {
                LocalSTTShadow(
                    path: "dictation",
                    engine: A62819DictationFakeLocal(),
                    mic: { mic },
                    log: { shadowLogs.append($0) }
                )
            }
        } else {
            engine.localSTTShadow(nil)
        }

        controller.configureEngine()
        defer { engine.cancel() }

        var ends: [String] = []
        var started = false
        controller.onSessionNote = {
            if $0.contains("event=start") { started = true }
            if $0.contains("event=end") { ends.append($0) }
        }

        let rig = root.appendingPathComponent("rig")
        try FileManager.default.createDirectory(at: rig, withIntermediateDirectories: true)
        #expect(engine.enableRig(launchEnvironment: ["DICTATE_RIG": "1", "DICTATE_RIG_DIR": rig.path]) {
            engine.handle($0 == .tap ? .tap : .doubleTap)
        })

        let trigger = rig.appendingPathComponent("trigger")
        #expect(FileManager.default.createFile(
            atPath: trigger.path,
            contents: Data("chord selftest\n".utf8),
            attributes: [.posixPermissions: 0o600]
        ))
        try await waitFor { recorder.isRunning && started && !controller.micStartPending }

        let ticks = max(1, (samples.count + AudioRecorder.chunkSamples - 1) / AudioRecorder.chunkSamples) + 5
        for _ in 0..<ticks {
            wave.step()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        if ends.isEmpty {
            #expect(FileManager.default.createFile(
                atPath: trigger.path,
                contents: Data("chord selftest\n".utf8),
                attributes: [.posixPermissions: 0o600]
            ))
        }
        try await waitFor { !ends.isEmpty }

        if withShadow {
            try await waitFor { shadowLogs.count >= 1 }
            try await Task.sleep(for: .milliseconds(50))
        }

        let outcome = ends.first?.split(separator: " ").first { $0.hasPrefix("outcome=") }.map(String.init) ?? "outcome=missing"
        let output = rig.appendingPathComponent("out/selftest.txt")
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let cloudRequests = await http.groq + http.scribe
        return RunResult(outcome: outcome, text: text, cloudRequests: cloudRequests, shadowLines: shadowLogs.all)
    }

    private func verifyFixture(filename: String, tag: String, mic: String) async throws {
        let wav = Self.fixturesDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: wav.path) else {
            print("SKIP real_text_identical_\(tag) reason=missing_fixture path=\(wav.path)")
            return
        }
        let samples = try WAVInjectedRecorder.parseWAV(at: wav)
        let base = try await runDictation(wav: wav, samples: samples, mic: mic, withShadow: false)
        let shadowed = try await runDictation(wav: wav, samples: samples, mic: mic, withShadow: true)

        let textEqual = !base.text.isEmpty && shadowed.text == base.text
        let requestsEqual = base.cloudRequests >= 1 && shadowed.cloudRequests == base.cloudRequests
        let hasShadowLines = !shadowed.shadowLines.isEmpty
            && shadowed.shadowLines.allSatisfy {
                $0.contains("stt_shadow") && $0.contains("path=dictation") && $0.contains("mic=\(mic)")
            }
        let ok = base.outcome == "outcome=ok"
            && shadowed.outcome == "outcome=ok"
            && textEqual
            && requestsEqual
            && hasShadowLines
        print("P \(ok ? "GREEN" : "RED") real_text_identical_\(tag)=\(ok ? 1 : 0) path=dictation text_equal=\(textEqual ? 1 : 0) requests=\(shadowed.cloudRequests)/\(base.cloudRequests) lines=\(shadowed.shadowLines.count)")
        #expect(ok)
    }

    @Test func dictation_shadow_preserves_text_macmic() async throws {
        try await verifyFixture(filename: "voice-question-macbook.wav", tag: "macmic", mic: "builtin")
    }

    @Test func dictation_shadow_preserves_text_headset() async throws {
        try await verifyFixture(filename: "voice-passage.wav", tag: "headset", mic: "headset")
    }
}
