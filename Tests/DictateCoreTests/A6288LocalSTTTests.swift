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
        let ok = [first, second].allSatisfy { $0.result.text == "from groq" && $0.result.localFallbacks == 1 && $0.ms < 1_500 }
        print("P \(ok ? "GREEN" : "RED") dead_helper_falls_back=\(ok ? 1 : 0) first_ms=\(first.ms) second_ms=\(second.ms)")
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
        let tone = (0..<16_000).map { Int16(sin(Double($0) / 16.0) * 3_000) }
        let answers = try await [engine.transcribe(pcm16k: tone), engine.transcribe(pcm16k: [Int16](repeating: 0, count: 8_000))]
        print("P GREEN real_helper_answers=\(answers.count) texts=\(answers.map { "\"\($0)\"" }.joined(separator: ","))")
        #expect(answers.count == 2)
    }
}
