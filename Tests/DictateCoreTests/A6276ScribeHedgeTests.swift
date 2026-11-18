import Foundation
import Testing
import DictateCore

/// archie-6276 Fix 2 (Dictate 1.29.9): a slow Groq never stalls hearing. Check A: `request_ms=7691`,
/// `request_ms=9895` (dictation), `wait_ms=8073 reason=groq_http_network` (conversation). A chunk Groq
/// has not answered within ~2 s also goes to Scribe; the first good answer wins. Fake transport only.
private actor HedgeTransport: HTTPTransport {
    let groqDelayMs: Int, scribeDelayMs: Int
    private(set) var groqRequests = 0, scribeRequests = 0
    init(groqDelayMs: Int, scribeDelayMs: Int) { self.groqDelayMs = groqDelayMs; self.scribeDelayMs = scribeDelayMs }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let scribe = request.url == ScribeClient.endpoint
        if scribe { scribeRequests += 1 } else { groqRequests += 1 }
        try await Task.sleep(for: .milliseconds(scribe ? scribeDelayMs : groqDelayMs))
        let body = try JSONSerialization.data(withJSONObject: ["text": scribe ? "from scribe" : "from groq"])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@Suite("A6276ScribeHedgeTests", .serialized)
struct A6276ScribeHedgeTests {
    /// The dictation transcriber as DictateKit builds it, with a Scribe key; one 0.4 s chunk (debug-build resampling stays out of the timing).
    static func run(groqMs: Int, scribeMs: Int) async -> (ms: Int, text: String, result: GroqChunkedTranscriber.Result, groq: Int, scribe: Int) {
        let transport = HedgeTransport(groqDelayMs: groqMs, scribeDelayMs: scribeMs)
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "groq-key" }, prompt: "Archie",
                                            fillerLeadIn: false, scribeAPIKey: { "scribe-key" })
        let start = ContinuousClock.now
        engine.submit(PauseChunker.Chunk(index: 0, samples: [Int16](repeating: 900, count: 9_600), cutKind: .pause, quietRunMs: 250))
        let result = await engine.finish()
        let d = ContinuousClock.now - start
        let ms = Int(d.components.seconds * 1_000 + d.components.attoseconds / 1_000_000_000_000_000)
        return (ms, result.text, result, await transport.groqRequests, await transport.scribeRequests)
    }

    /// Groq 8 s, Scribe 0.5 s. RED (1.29.8): waits for Groq ~8 s. GREEN: Scribe's answer by ~2.5 s.
    @Test func slow_groq_dictation_hedged() async {
        let r = await Self.run(groqMs: 8_000, scribeMs: 500)
        let won = r.result.calls.first { $0.winningRequest != nil }
        print("P \(r.ms <= 3_000 ? "GREEN" : "RED") slow_groq_dictation_hedged wait_ms=\(r.ms) text=\"\(r.text)\" winner_model=\(won?.model ?? "-") groq_requests=\(r.groq) scribe_requests=\(r.scribe)")
        #expect(r.ms <= 3_000 && r.text == "from scribe" && r.result.scribeChunks == 1)
        #expect(won?.model == ScribeClient.model && won?.hedgeFired == true && won?.winningRequest == 3)
    }

    /// Groq answers in 0.3 s: no Scribe request is ever made.
    @Test func fast_groq_no_scribe_call() async {
        let r = await Self.run(groqMs: 300, scribeMs: 500)
        print("P \(r.scribe == 0 ? "GREEN" : "RED") fast_groq_no_scribe_call=\(r.scribe == 0 ? 1 : 0) wait_ms=\(r.ms) text=\"\(r.text)\" scribe_requests=\(r.scribe)")
        #expect(r.scribe == 0 && r.text == "from groq" && r.result.scribeChunks == 0)
    }
}

/// Fable read 2: Groq refuses attempt 1 at once (429), then attempt 2 hangs 8 s — Scribe still answers by ~2.5 s.
private actor FailThenSlow: HTTPTransport {
    private(set) var groq = 0, scribe = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isScribe = request.url == ScribeClient.endpoint
        if isScribe { scribe += 1 } else { groq += 1 }
        let n = groq
        if !isScribe && n == 1 {
            return (Data(#"{"error":"rate"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        }
        try await Task.sleep(for: .milliseconds(isScribe ? 500 : 8_000))
        let body = try JSONSerialization.data(withJSONObject: ["text": isScribe ? "from scribe" : "from groq"])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension A6276ScribeHedgeTests {
    @Test func slow_groq_second_attempt_hedged() async {
        let transport = FailThenSlow()
        let engine = GroqChunkedTranscriber(transport: transport, apiKey: { "groq-key" }, prompt: "Archie",
                                            fillerLeadIn: false, scribeAPIKey: { "scribe-key" })
        let start = ContinuousClock.now
        engine.submit(PauseChunker.Chunk(index: 0, samples: [Int16](repeating: 900, count: 9_600), cutKind: .pause, quietRunMs: 250))
        let result = await engine.finish()
        let d = ContinuousClock.now - start
        let ms = Int(d.components.seconds * 1_000 + d.components.attoseconds / 1_000_000_000_000_000)
        print("P \(ms <= 3_000 ? "GREEN" : "RED") slow_groq_second_attempt_hedged wait_ms=\(ms) text=\"\(result.text)\" scribe_requests=\(await transport.scribe)")
        #expect(ms <= 3_000 && result.text == "from scribe")
    }
}
