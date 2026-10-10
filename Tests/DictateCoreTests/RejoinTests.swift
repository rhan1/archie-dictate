import Foundation
import Testing
import DictateCore

/// Auto-replying fake STT: the tag is the first sample; a joined pair is the one
/// request whose WAV data is longer than any single 2400-sample chunk.
private actor ScriptedSTT: HTTPTransport {
    private(set) var requests: [(tag: Int, wavBytes: Int)] = []
    private let reply: @Sendable (Int, Bool) -> String
    private let delayMs: [Int: Int]
    init(delayMs: [Int: Int] = [:], _ reply: @escaping @Sendable (Int, Bool) -> String) {
        self.delayMs = delayMs
        self.reply = reply
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody!
        let riff = body.range(of: Data("RIFF".utf8))!.lowerBound
        let tag = Int(Int16(bitPattern: UInt16(body[riff + 44]) | UInt16(body[riff + 45]) << 8))
        let bytes = (0..<4).reduce(0) { $0 | Int(body[riff + 40 + $1]) << (8 * $1) }
        requests.append((tag, bytes))
        if let delay = delayMs[tag], bytes < 5_000 { try await Task.sleep(for: .milliseconds(delay)) }
        let data = try JSONSerialization.data(withJSONObject: ["text": reply(tag, bytes > 5_000)])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    var joined: Int { requests.filter { $0.wavBytes > 5_000 }.count }
}

/// Echoes the <dictation> body back so the test sees exactly what the cleaner was given.
private actor EchoCleaner: HTTPTransport {
    private(set) var dictations: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let user = (body["messages"] as! [[String: String]]).last!["content"]!
        let text = user.components(separatedBy: "<dictation>").last!.components(separatedBy: "</dictation>").first!
        dictations.append(text)
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": text]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func samples(_ tag: Int) -> [Int16] { Array(repeating: Int16(tag), count: 2400) }

@Suite("D5 rejoin guard")
struct RejoinTests {
    static let head = "Um, so for the Politrace launch, send the draft to the team on Tuesday, no, Wednesday. We need, like, three things: the Limpar match counts, the DB99 query, and,"
    static let tail = "other screenshots. Can you also check if TurnoutWatch is still running?"
    static let joinedText = "Um, so for the Politrace launch, send the draft to the team on Tuesday, no, Wednesday. We need, like, three things: the Limpar match counts, the DB99 query, and, uh, the screenshots. Can you also check if TurnoutWatch is still running?"

    /// Two chunks; chunk 0 (tag 1000) is cut as `kind`; the pair request is the only 6400-byte one.
    private func run(first: String, second: String, joined: String, kind: PauseChunker.CutKind = .pause,
                     quietMs: Int? = 150) async -> (GroqChunkedTranscriber.Result, ScriptedSTT) {
        let stt = ScriptedSTT { tag, pair in pair ? joined : tag == 1000 ? first : second }
        let engine = GroqChunkedTranscriber(transport: stt, apiKey: { "k" }, prompt: "", hedgeAfterMs: 60000, rejoinGuard: true)
        engine.submit(.init(index: 0, samples: samples(1000), cutKind: kind, quietRunMs: quietMs))
        engine.submit(.init(index: 1, samples: samples(2000)), isFinal: true)
        return (await engine.finish(), stt)
    }

    @Test(arguments: [PauseChunker.CutKind.pause, .forced]) func r5OtherScreenshotsIsRejoined(kind: PauseChunker.CutKind) async {
        let (result, stt) = await run(first: Self.head, second: Self.tail, joined: Self.joinedText, kind: kind,
                                      quietMs: kind == .pause ? 150 : nil)
        #expect(result.text.contains("the screenshots"))
        #expect(!result.text.contains("other screenshots"))
        #expect(result.text == Self.joinedText)
        #expect(result.rejoins == 1)
        #expect(await stt.requests.count == 3)  // two chunks + exactly one pair request
        #expect(await stt.joined == 1)
        #expect(result.calls.filter { $0.isRejoin }.count == 1)
    }

    @Test func longPauseIsNotRejoined() async {
        let (result, stt) = await run(first: Self.head, second: Self.tail, joined: Self.joinedText, quietMs: 400)
        #expect(result.text == Self.head + " " + Self.tail)
        #expect(result.rejoins == 0)
        #expect(await stt.requests.count == 2)
    }

    @Test func sentenceEndIsNotRejoined() async {
        let (result, stt) = await run(first: "Send the DB99 query.", second: Self.tail, joined: "WRONG")
        #expect(result.text == "Send the DB99 query. " + Self.tail)
        #expect(result.rejoins == 0)
        #expect(await stt.requests.count == 2)
    }

    @Test func noTriggerAddsNoRequest() async {
        let (result, stt) = await run(first: "and the", second: "screenshots are ready", joined: "WRONG")
        #expect(result.text == "and the screenshots are ready")
        #expect(result.rejoins == 0)
        #expect(await stt.requests.count == 2)
    }

    @Test func r5CheckItQuestionIsRejoined() async {
        let joined = "Then can you also check if TurnoutWatch is still running?"
        let (result, stt) = await run(first: "Then can you also check it?", second: "TurnoutWatch this still running?",
                                      joined: joined, kind: .forced, quietMs: nil)
        #expect(result.text == joined)
        #expect(result.rejoins == 1)
        #expect(await stt.joined == 1)
    }

    @Test func appDefaultIsOnAndEnvDisables() {
        #expect(GroqChunkedTranscriber.rejoinGuardEnabled(environment: [:]))
        #expect(GroqChunkedTranscriber.rejoinGuardEnabled(environment: ["DICTATE_REJOIN_GUARD": "1"]))
        #expect(!GroqChunkedTranscriber.rejoinGuardEnabled(environment: ["DICTATE_REJOIN_GUARD": "0"]))
    }

    @Test func failedPairKeepsBothChunks() async {
        let stt = ScriptedSTT { tag, pair in pair ? "" : tag == 1000 ? "and, uh" : "other screenshots" }
        let engine = GroqChunkedTranscriber(transport: stt, apiKey: { "k" }, prompt: "", hedgeAfterMs: 60000, rejoinGuard: true)
        engine.submit(.init(index: 0, samples: samples(1000), cutKind: .pause, quietRunMs: 150))
        engine.submit(.init(index: 1, samples: samples(2000)), isFinal: true)
        let result = await engine.finish()
        #expect(result.text == "and, uh other screenshots")
        #expect(result.rejoins == 1)
    }

    @Test func atMostTwoRejoinsPerDictation() async {
        // Three adjacent trigger pairs: (0,1) (2,3) (4,5). Only the first two may be re-sent.
        let stt = ScriptedSTT { tag, pair in pair ? "joined\(tag)" : (tag / 1000 - 1) % 2 == 0 ? "and," : "other x" }
        let engine = GroqChunkedTranscriber(transport: stt, apiKey: { "k" }, prompt: "", hedgeAfterMs: 60000, rejoinGuard: true)
        for index in 0..<6 {
            engine.submit(.init(index: index, samples: samples((index + 1) * 1000),
                                cutKind: .pause, quietRunMs: 150), isFinal: index == 5)
        }
        let result = await engine.finish()
        #expect(result.rejoins == 2)
        #expect(await stt.joined == 2)
        #expect(await stt.requests.count == 8)
    }

    /// The app runs incremental cleanup on chunk texts as they land; the rejoin happens
    /// afterwards, so the final cleanup must see the rejoined text, not the stale chunk.
    @Test func incrementalCleanupSeesRejoinedText() async {
        let texts = ["Send the draft to the team on Tuesday, no, Wednesday.", "We need three things, the DB99 query, and,",
                     "other screenshots. Can you also check if TurnoutWatch is still running?", "Thanks."]
        let joined = "We need three things, the DB99 query, and, uh, the screenshots. Can you also check if TurnoutWatch is still running?"
        // Chunk 0 lands last, so the first mid batch is [0,2): it already holds the boundary's first half.
        let stt = ScriptedSTT(delayMs: [1000: 80]) { tag, pair in pair ? joined : texts[tag / 1000 - 1] }
        let echo = EchoCleaner()
        var cleaner = TranscriptCleaner(transport: echo, vocabulary: "", apiKey: { "k" })
        cleaner.hintsSentence = ""
        let incremental = IncrementalCleaner(cleaner: cleaner)
        let engine = GroqChunkedTranscriber(transport: stt, apiKey: { "k" }, prompt: "", hedgeAfterMs: 60000, rejoinGuard: true,
                                            onChunkText: { index, text in incremental.append(index: index, text: text) })
        engine.submit(.init(index: 0, samples: samples(1000), cutKind: .pause, quietRunMs: 800))
        engine.submit(.init(index: 1, samples: samples(2000), cutKind: .pause, quietRunMs: 150))
        engine.submit(.init(index: 2, samples: samples(3000), cutKind: .pause, quietRunMs: 800))
        // Mid-dictation: the first batch (chunks 0-1, which hold the boundary) is cleaned before the tap.
        for _ in 0..<2000 where await echo.dictations.isEmpty { try? await Task.sleep(for: .milliseconds(1)) }
        await incremental.waitForPending()
        #expect(await echo.dictations.count == 1)
        incremental.seal()
        engine.submit(.init(index: 3, samples: samples(4000)), isFinal: true)
        let result = await engine.finish()
        #expect(result.rejoins == 1)
        #expect(result.text.contains("the screenshots"))
        await incremental.waitForPending()
        let raw = LockedBox()
        let output = await incremental.finish(totalChunks: result.chunks, rawText: result.text, single: { text in
            raw.set(text)
            return .init(text: text, label: "ok", model: "fake", stats: nil, calls: 1)
        })
        let pasted = output.text ?? ""
        #expect(pasted.contains("the screenshots"))
        #expect(!pasted.contains("other screenshots"))
        #expect(!(await echo.dictations.contains { $0.contains("other screenshots") }))
        #expect(output.skippedReason == "rejoin_replaced")
        #expect(raw.text == result.text)
    }
}

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ text: String) { lock.withLock { value = text } }
    var text: String? { lock.withLock { value } }
}
