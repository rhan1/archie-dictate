import Foundation
import Testing
import DictateCore

/// Scripted Groq: each chunk is recognised by its WAV data size, so responses can be given per
/// chunk, out of order (delays) or failed (status). No network, no Groq spend.
private actor ScriptedTransport: HTTPTransport {
    struct Reply: Sendable {
        let text: String
        var delayMs = 0
        var status = 200
    }
    private let replies: [Int: Reply]

    init(_ replies: [Int: Reply]) { self.replies = replies }

    static func key(_ samples: [Int16]) -> Int { (samples.count * 2 / 3) * 2 }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody!
        let riff = body.range(of: Data("RIFF".utf8))!.lowerBound
        let size = (0..<4).reduce(0) { $0 | Int(body[riff + 40 + $1]) << (8 * $1) }
        let reply = replies[size] ?? Reply(text: "", status: 500)
        if reply.delayMs > 0 { try await Task.sleep(for: .milliseconds(reply.delayMs)) }
        let data = try JSONSerialization.data(withJSONObject: ["text": reply.text])
        return (data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class Stream: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(Int, String)] = []
    func add(_ index: Int, _ text: String) { lock.withLock { events.append((index, text)) } }
    func texts(_ index: Int) -> [String] { lock.withLock { events.filter { $0.0 == index }.map(\.1) } }
}

/// v1.11 L1: invented sentences at a dictation's edges are dropped on audio evidence only;
/// uncertain text is kept (GPT-6 review §F "Transcript integrity", §H; Fable 10-13).
/// Lines marked `// v1.11-api` use v1.11 fields; the RED runs on v1.10 strip them.
@Suite("EdgeSentenceGuard", .serialized)
struct EdgeSentenceGuardTests {
    // 220 Hz at 3000 is speech by any rule (−27 dBFS RMS); ±15 is −67 dBFS room noise (never
    // speech); a 50 ms burst is a key click (one window: no section, no speech run).
    private func tone(_ seconds: Double, amplitude: Double = 3_000) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { Int16((amplitude * sin(2 * .pi * 220 * Double($0) / 24_000)).rounded()) }
    }
    private func noise(_ seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { $0.isMultiple(of: 2) ? 15 : -15 }
    }
    private var click: [Int16] { tone(0.05) }

    private func run(_ chunks: [([Int16], ScriptedTransport.Reply)], prompt: String = "Politrace",
                     lowSpeechGuard: Bool? = nil, concurrent: Bool = false,
                     stream: Stream? = nil) async -> GroqChunkedTranscriber.Result {
        var replies: [Int: ScriptedTransport.Reply] = [:]
        for (samples, reply) in chunks { replies[ScriptedTransport.key(samples)] = reply }
        #expect(Set(chunks.map { ScriptedTransport.key($0.0) }).count == chunks.count, "chunk durations must differ")
        let transport = ScriptedTransport(replies)
        let stt: GroqChunkedTranscriber
        if let lowSpeechGuard {
            stt = GroqChunkedTranscriber(transport: transport, apiKey: { "test-key" }, prompt: prompt,
                fillerLeadIn: false, hedgeAfterMs: 60_000, lowSpeechGuard: lowSpeechGuard,
                onChunkText: { index, text in stream?.add(index, text) })
        } else {
            stt = GroqChunkedTranscriber(transport: transport, apiKey: { "test-key" }, prompt: prompt,
                fillerLeadIn: false, hedgeAfterMs: 60_000, onChunkText: { index, text in stream?.add(index, text) })
        }
        var tasks: [Task<Void, Never>] = []
        for (index, chunk) in chunks.enumerated() {
            let task = stt.submit(.init(index: index, samples: chunk.0), isFinal: index == chunks.count - 1)
            if concurrent { task.map { tasks.append($0) } } else { await task?.value }
        }
        return await stt.finish()
    }

    private let report = "Send the report to Maria."

    // MARK: tail

    /// RED on v1.10 (the last chunk was never judged): a sentence over the non-speech after the
    /// last speech section is dropped.
    @Test func tailSilenceSentenceDropped() async {
        let last = tone(2.0) + noise(1.5) + click + noise(0.25)
        let result = await run([(tone(1.0), .init(text: report)),
                                (last, .init(text: "Okay, that is everything. Have a great weekend."))])
        #expect(result.text == "Send the report to Maria. Okay, that is everything.")
        #expect(result.droppedTailSentences == 1) // v1.11-api
        #expect(result.droppedArtifacts == 0) // v1.11-api
    }

    /// RED on v1.10: Raza's "Thank you" after the real end of his speech.
    @Test func tailThankYouAfterLastSpeechDropped() async {
        let last = tone(2.0) + noise(1.5) + click + noise(0.25)
        let result = await run([(tone(1.0), .init(text: "Okay, here is the plan.")),
                                (last, .init(text: "Send the report to Maria. Thank you."))])
        #expect(result.text == "Okay, here is the plan. Send the report to Maria.")
        #expect(result.droppedArtifacts == 1) // v1.11-api
    }

    /// RED on v1.10: the vocabulary prompt's "Dictate" on the tail's silence.
    @Test func dictateArtifactAfterSilenceDropped() async {
        let last = tone(1.5) + noise(2.0) + click + noise(0.25)
        let result = await run([(tone(1.0), .init(text: report)), (last, .init(text: "Okay, ship it. Dictate."))])
        #expect(result.text == "Send the report to Maria. Okay, ship it.")
        #expect(result.droppedArtifacts == 1) // v1.11-api
    }

    /// "Thanks" IS speech when the audio ends in speech: the passage ends inside its last section.
    @Test func thanksInsideSpeechKept() async {
        let result = await run([(tone(1.0), .init(text: report)),
                                (tone(2.5) + noise(0.25), .init(text: "That is all for today. Thanks."))])
        #expect(result.text == "Send the report to Maria. That is all for today. Thanks.")
        #expect(result.droppedTailSentences + result.droppedArtifacts == 0) // v1.11-api
    }

    /// A click 0.4 s after the last word leaves < 1 s of non-speech: the honest ending is kept.
    @Test func honestEndingBeforeClickKept() async {
        let last = tone(2.5) + noise(0.4) + click + noise(0.25)
        let result = await run([(tone(1.0), .init(text: report)), (last, .init(text: "Send it now. Thank you."))])
        #expect(result.text == "Send the report to Maria. Send it now. Thank you.")
    }

    /// Soft words (6 dB over the dictation's floor, under its speech threshold) veto a drop.
    @Test func softWordsVetoTheDrop() async {
        let last = tone(1.0) + noise(0.3) + tone(0.5, amplitude: 60) + noise(1.2) + click + noise(0.25)
        let result = await run([(tone(1.0), .init(text: report)), (last, .init(text: "Send it. Then call Maria."))])
        #expect(result.text == "Send the report to Maria. Send it. Then call Maria.")
    }

    // MARK: silent chunks

    @Test func silentLastChunkDropped() async {
        let stream = Stream()
        let result = await run([(tone(1.0), .init(text: report)), (noise(1.5), .init(text: "Thank you."))], stream: stream)
        #expect(result.text == report)
        #expect(result.droppedSilentChunks == 1) // v1.11-api
        #expect(stream.texts(1) == [""])
    }

    /// The silent chunk's text never reaches the incremental cleaner (it pastes as it goes).
    @Test func silentMiddleChunkNeverStreamed() async {
        let stream = Stream()
        let result = await run([(tone(1.0), .init(text: report)), (noise(1.5), .init(text: "Dictate.")),
                                (tone(0.8), .init(text: "Then call the bank."))], stream: stream)
        #expect(result.text == "Send the report to Maria. Then call the bank.")
        #expect(stream.texts(1) == [""])
    }

    /// Quiet input does not manufacture text.
    @Test func quietInputManufacturesNothing() async {
        let result = await run([(noise(2.0), .init(text: "Thank you."))])
        #expect(result.text == "")
        #expect(result.droppedSilentChunks == 1) // v1.11-api
    }

    // MARK: opening

    @Test func openingArtifactBeforeFirstSpeechDropped() async {
        let first = noise(1.5) + click + noise(0.2) + tone(2.0)
        let result = await run([(first, .init(text: "Thank you. Book the flight to Denver.")),
                                (tone(1.0), .init(text: "Then email Maria."))])
        #expect(result.text == "Book the flight to Denver. Then email Maria.")
        #expect(result.droppedArtifacts == 1) // v1.11-api
    }

    @Test func openingSentenceOverSilenceDropped() async {
        let first = noise(1.5) + click + noise(0.2) + tone(2.0)
        let result = await run([(first, .init(text: "Okay so. Book the flight to Denver.")),
                                (tone(1.0), .init(text: "Then email Maria."))])
        #expect(result.text == "Book the flight to Denver. Then email Maria.")
        #expect(result.droppedOpeningSentences == 1) // v1.11-api
    }

    // MARK: transcript integrity (GPT-6 review §F)

    /// The review's literal: a speech ratio of 0.10, "Hey. Cancel the London booking.", vocabulary
    /// "Politrace", next text "Send the invoice tomorrow." RED on v1.10 (the novelty rule was on).
    @Test func londonBookingSurvives() async {
        let low = tone(0.3) + noise(2.7)
        #expect(abs(LowSpeechSentenceGuard.speechRatio(of: low) - 0.10) < 0.02)
        let result = await run([(low, .init(text: "Hey. Cancel the London booking.")),
                                (tone(1.1), .init(text: "Send the invoice tomorrow."))])
        #expect(result.text == "Hey. Cancel the London booking. Send the invoice tomorrow.")
        #expect(result.droppedLowSpeechSentences == 0)
    }

    @Test func numbersNegationAndNamesExact() async {
        let texts = ["Wire $1,250.75 to account 4471 by 5.30 p.m.", "Do not cancel the London booking.",
                     "Ask Siobhan O'Neill and Raza Khan, version 1.11."]
        let result = await run([(tone(1.0), .init(text: texts[0])), (tone(1.2), .init(text: texts[1])),
                                (tone(0.9) + noise(0.25), .init(text: texts[2]))])
        #expect(result.text == texts.joined(separator: " "))
    }

    /// Responses arrive 2, 0, 1: the text is still in chunk order.
    @Test func reorderedResponsesKeepOrder() async {
        let result = await run([(tone(1.0), .init(text: "First this.", delayMs: 150)),
                                (tone(1.2), .init(text: "Then that.", delayMs: 300)),
                                (tone(0.9), .init(text: "Finally done."))], concurrent: true)
        #expect(result.text == "First this. Then that. Finally done.")
    }

    /// RED on v1.10 (review §H): with the novelty rule ON, chunk 2 answering before chunk 1 must not
    /// become chunk 0's comparator — chunk 1 shares chunk 0's words, chunk 2 does not.
    @Test func earlyLaterChunkIsNeverTheComparator() async {
        let low = tone(0.3) + noise(2.7)
        let result = await run([(low, .init(text: "Hey. Cancel the London booking.", delayMs: 100)),
                                (tone(1.2), .init(text: "The London booking was for Friday.", delayMs: 300)),
                                (tone(0.9), .init(text: "Send the invoice tomorrow."))],
                               lowSpeechGuard: true, concurrent: true)
        #expect(result.text == "Hey. Cancel the London booking. The London booking was for Friday. Send the invoice tomorrow.")
        #expect(result.droppedLowSpeechSentences == 0)
    }

    /// A chunk that fails twice is missing; nothing is invented in its place and its neighbours are exact.
    @Test func missingChunkLeavesNeighboursExact() async {
        let result = await run([(tone(1.0), .init(text: "First this.")),
                                (tone(1.2), .init(text: "lost", status: 500)),
                                (tone(0.9), .init(text: "Finally done."))])
        #expect(result.text == "First this. Finally done.")
        #expect(result.failedCount == 1)
    }

    @Test func edgeGuardSwitchDefaultsToEnabled() {
        #expect(GroqChunkedTranscriber.edgeGuardEnabled(environment: [:])) // v1.11-api
        #expect(!GroqChunkedTranscriber.edgeGuardEnabled(environment: ["DICTATE_EDGE_GUARD": "0"])) // v1.11-api
    }
}
