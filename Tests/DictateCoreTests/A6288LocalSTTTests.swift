import Foundation
import Testing
import DictateCore

/// archie-6288 (Dictate 1.29.15): an on-device engine handed to the chunked transcriber answers first; an error,
/// an empty answer, a hang or a dead helper sends the chunk down the unchanged cloud path (Groq → Scribe hedge).
private actor CloudCounter: HTTPTransport {
    let groqMs: Int
    private(set) var groq = 0, scribe = 0
    init(groqMs: Int = 50) { self.groqMs = groqMs }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isScribe = request.url == ScribeClient.endpoint
        if isScribe { scribe += 1 } else { groq += 1 }
        try await Task.sleep(for: .milliseconds(isScribe ? 300 : groqMs))
        let body = try JSONSerialization.data(withJSONObject: ["text": isScribe ? "from scribe" : "from groq"])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct FakeLocal: LocalChunkSTT {
    enum Mode { case text(String), fail, hang }
    let mode: Mode
    var modelID: String { "fake-local" }
    func transcribe(pcm16k: [Int16]) async throws -> String {
        switch mode {
        case .text(let text): return text
        case .fail: throw LocalSTTError.engine("7")
        case .hang: try await Task.sleep(for: .seconds(30)); return "too late"
        }
    }
}

@Suite("A6288LocalSTTTests", .serialized)
struct A6288LocalSTTTests {
    static func run(_ local: (any LocalChunkSTT)?, groqMs: Int = 50) async
        -> (ms: Int, result: GroqChunkedTranscriber.Result, groq: Int, scribe: Int) {
        let cloud = CloudCounter(groqMs: groqMs)
        let engine = GroqChunkedTranscriber(transport: cloud, apiKey: { "groq-key" }, prompt: "Archie",
                                            fillerLeadIn: false, scribeAPIKey: { "scribe-key" }, local: local)
        let start = ContinuousClock.now
        engine.submit(PauseChunker.Chunk(index: 0, samples: [Int16](repeating: 900, count: 9_600), cutKind: .pause, quietRunMs: 250))
        let result = await engine.finish()
        let d = ContinuousClock.now - start
        let ms = Int(d.components.seconds * 1_000 + d.components.attoseconds / 1_000_000_000_000_000)
        return (ms, result, await cloud.groq, await cloud.scribe)
    }

    /// RED (mutation: the `upload` hook removed): Groq answers, local never asked. GREEN: local text, zero cloud requests.
    @Test func local_stt_routes_when_on() async {
        let r = await Self.run(FakeLocal(mode: .text("from local")))
        let ok = r.result.text == "from local" && r.groq == 0 && r.scribe == 0 && r.result.localChunks == 1
        print("P \(ok ? "GREEN" : "RED") local_stt_routes_when_on=\(ok ? 1 : 0) text=\"\(r.result.text)\" local_chunks=\(r.result.localChunks) cloud_requests=\(r.groq + r.scribe)")
        #expect(ok)
        #expect(r.result.calls.first?.model == "fake-local")
    }

    /// No local engine (the default): exactly today's Groq path.
    @Test func no_local_engine_is_cloud_only() async {
        let r = await Self.run(nil)
        #expect(r.result.text == "from groq" && r.groq == 1 && r.result.localChunks == 0 && r.result.localFallbacks == 0)
    }

    /// Error, empty answer, hang (> 1.5 s): the same chunk is answered by Groq; with Groq slow, by the Scribe hedge.
    @Test func local_failure_falls_back_to_cloud() async {
        let failed = await Self.run(FakeLocal(mode: .fail))
        let empty = await Self.run(FakeLocal(mode: .text("  ")))
        let hung = await Self.run(FakeLocal(mode: .hang))
        let hedged = await Self.run(FakeLocal(mode: .fail), groqMs: 8_000)
        let ok = failed.result.text == "from groq" && empty.result.text == "from groq" && hung.result.text == "from groq"
            && hung.ms < GroqChunkedTranscriber.localTimeoutMs + 1_500 && hedged.result.text == "from scribe"
            && [failed, empty, hung, hedged].allSatisfy { $0.result.localFallbacks == 1 && $0.result.localChunks == 0 && $0.result.failedCount == 0 }
        print("P \(ok ? "GREEN" : "RED") local_failure_falls_back_to_cloud=\(ok ? 1 : 0) error=\"\(failed.result.text)\" empty=\"\(empty.result.text)\" hang=\"\(hung.result.text)\" hang_ms=\(hung.ms) groq_slow=\"\(hedged.result.text)\"")
        #expect(ok)
    }

    /// The real process client against a helper that dies at once: an error (no hang, no SIGPIPE), then Groq.
    @Test func dead_helper_falls_back_to_cloud() async {
        let dead = LocalSTTProcess(executable: URL(fileURLWithPath: "/usr/bin/false"), model: URL(fileURLWithPath: "/dev/null"))
        let first = await Self.run(dead)
        let second = await Self.run(dead)
        // The dead helper's closed stdout must not keep a reader spinning (idle CPU over 1 s after it died).
        func cpuMs() -> Int { var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Int(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1_000 + Int(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000 }
        let cpu0 = cpuMs()
        try? await Task.sleep(for: .seconds(1))
        let idleCPU = cpuMs() - cpu0
        let ok = [first, second].allSatisfy { $0.result.text == "from groq" && $0.result.localFallbacks == 1 && $0.ms < 1_500 } && idleCPU < 800     // a spinning reader is ~1000 ms per second
        print("P \(ok ? "GREEN" : "RED") dead_helper_falls_back=\(ok ? 1 : 0) first_ms=\(first.ms) second_ms=\(second.ms) idle_cpu_ms_after=\(idleCPU)")
        #expect(ok)
    }

    /// The real helper + Parakeet when installed (`stt-local` under Archie's Application Support); skipped otherwise.
    @Test func real_helper_transcribes() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Archie/stt-local")
        let helper = root.appendingPathComponent("bin/archie-stt-local"), model = root.appendingPathComponent("models/parakeet-tdt-0.6b-v2-Q8_0.gguf")
        guard FileManager.default.isExecutableFile(atPath: helper.path), FileManager.default.fileExists(atPath: model.path) else {
            print("P SKIP real_helper_transcribes reason=no_stt_local"); return
        }
        let engine = LocalSTTProcess(executable: helper, model: model)
        engine.prewarm()
        try await Task.sleep(for: .seconds(2))                // model loaded (READY)
        let tone = (0..<16_000).map { Int16(sin(Double($0) / 16.0) * 3_000) }
        let answers = try await [engine.transcribe(pcm16k: tone), engine.transcribe(pcm16k: [Int16](repeating: 0, count: 8_000))]
        print("P GREEN real_helper_answers=\(answers.count) texts=\(answers.map { "\"\($0)\"" }.joined(separator: ","))")
        #expect(answers.count == 2)
    }

    /// A fake helper (shell script) that takes the model argument and behaves as `body` says.
    static func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("a6288-helper-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    static func alive(_ helper: URL) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", helper.lastPathComponent]
        p.standardOutput = FileHandle.nullDevice; try? p.run(); p.waitUntilExit(); return p.terminationStatus == 0
    }

    /// Reads (Fable M2, Codex M1): a helper that stops answering costs ONE timeout — it is killed, and the next chunk
    /// goes to the cloud at once instead of waiting 1.5 s behind the abandoned one.
    @Test func hung_helper_costs_one_timeout() async throws {
        let helper = try Self.script("echo 'READY load_ms=1 backend=fake'\nwhile :; do read -r x || exit 0; done")   // stays `sh <script>`
        let engine = LocalSTTProcess(executable: helper, model: URL(fileURLWithPath: "/dev/null"))
        engine.prewarm()
        try await Task.sleep(for: .seconds(1))                // READY read
        let first = await Self.run(engine)
        let second = await Self.run(engine)
        let killed = !Self.alive(helper)
        let ok = first.result.text == "from groq" && first.ms >= 1_400 && second.result.text == "from groq" && second.ms < 700 && killed
        print("P \(ok ? "GREEN" : "RED") hung_helper_costs_one_timeout=\(ok ? 1 : 0) first_ms=\(first.ms) second_ms=\(second.ms) helper_killed=\(killed ? 1 : 0)")
        engine.stop()
        #expect(ok)
    }

    /// Fable M1: while the model is still loading (no READY yet) chunks go to the cloud at once, not after 1.5 s.
    @Test func loading_helper_is_skipped() async throws {
        let helper = try Self.script("sleep 5\necho READY\nexec cat > /dev/null")
        let engine = LocalSTTProcess(executable: helper, model: URL(fileURLWithPath: "/dev/null"))
        let r = await Self.run(engine)
        var emptyRefused = false
        do { _ = try await engine.transcribe(pcm16k: []) } catch { emptyRefused = error as? LocalSTTError == .unavailable }
        let ok = r.result.text == "from groq" && r.ms < 700 && emptyRefused
        print("P \(ok ? "GREEN" : "RED") loading_helper_is_skipped=\(ok ? 1 : 0) wait_ms=\(r.ms) empty_chunk_refused=\(emptyRefused ? 1 : 0)")
        engine.stop()
        #expect(ok)
    }

    /// Codex M3 / Fable m6: with a local engine, a rejoin-shaped boundary ("… check it" | "…") is not re-uploaded to Groq.
    @Test func local_chunks_not_rejoined_in_cloud() async {
        struct ByLength: LocalChunkSTT {
            var modelID: String { "fake-local" }
            func transcribe(pcm16k: [Int16]) async throws -> String { pcm16k.count > 7_000 ? "please check it" : "TurnoutWatch now" }
        }
        let cloud = CloudCounter()
        let engine = GroqChunkedTranscriber(transport: cloud, apiKey: { "groq-key" }, prompt: "Archie", fillerLeadIn: false,
                                            rejoinGuard: true, scribeAPIKey: { "scribe-key" }, local: ByLength())
        engine.submit(PauseChunker.Chunk(index: 0, samples: [Int16](repeating: 900, count: 12_000), cutKind: .forced, quietRunMs: nil))
        engine.submit(PauseChunker.Chunk(index: 1, samples: [Int16](repeating: 900, count: 9_600), cutKind: .pause, quietRunMs: 250))
        let result = await engine.finish()
        let groq = await cloud.groq
        let ok = groq == 0 && result.localChunks == 2 && result.rejoins == 0
        print("P \(ok ? "GREEN" : "RED") local_chunks_not_rejoined_in_cloud=\(ok ? 1 : 0) groq_requests=\(groq) rejoins=\(result.rejoins) text=\"\(result.text)\"")
        #expect(ok)
    }
}
