import Foundation
import Testing
import DictateCore

/// Scripted Groq: each chunk is recognised by its WAV data size, so responses can be given per
/// chunk, out of order (delays) or failed (status). No network, no Groq spend.
private actor ScriptedTransport: HTTPTransport {
    /// v1.28 FR4-A: Groq's `verbose_json` segment (seconds into the chunk's audio).
    struct Segment: Sendable {
        let start: Double; let end: Double; let text: String
        /// v1.28 FR5: Whisper's confidences (`no_speech_prob`, `avg_logprob`, `compression_ratio`); nil = not sent.
        var p: Double? = nil; var lp: Double? = nil; var cr: Double? = nil
    }
    struct Reply: Sendable {
        let text: String
        var delayMs = 0
        var status = 200
        var segments: [Segment]? = nil
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
        var json: [String: Any] = ["text": reply.text]
        if let segments = reply.segments {
            json["segments"] = segments.enumerated().map { item -> [String: Any] in
                var segment: [String: Any] = ["id": item.offset, "start": item.element.start, "end": item.element.end,
                                              "text": " " + item.element.text]
                if let p = item.element.p { segment["no_speech_prob"] = p }
                if let lp = item.element.lp { segment["avg_logprob"] = lp }
                if let cr = item.element.cr { segment["compression_ratio"] = cr }
                return segment
            }
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return (data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
}

/// v1.28 FR4-A: records each chunk request's `response_format` (keyed by WAV data size) and answers text only.
private actor FormatTransport: HTTPTransport {
    private(set) var formats: [Int: String] = [:]
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody!
        let riff = body.range(of: Data("RIFF".utf8))!.lowerBound
        let size = (0..<4).reduce(0) { $0 | Int(body[riff + 40 + $1]) << (8 * $1) }
        let text = String(decoding: body[..<riff], as: UTF8.self)
        if let range = text.range(of: "name=\"response_format\"\r\n\r\n") {
            formats[size] = String(text[range.upperBound...]).components(separatedBy: "\r\n").first ?? ""
        }
        let data = try JSONSerialization.data(withJSONObject: ["text": "Send the report."])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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
    /// v1.28 FR2-A: possible speech also needs ≥ −50 dBFS, so the soft word is at amplitude 200 (≈ −47 dBFS RMS,
    /// still under the −40 dBFS speech line); it was 60 (≈ −58 dBFS) — see the twin below.
    @Test func softWordsVetoTheDrop() async {
        let last = tone(1.0) + noise(0.3) + tone(0.5, amplitude: 200) + noise(1.2) + click + noise(0.25)
        let result = await run([(tone(1.0), .init(text: report)), (last, .init(text: "Send it. Then call Maria."))])
        #expect(result.text == "Send the report to Maria. Send it. Then call Maria.")
    }

    /// v1.28 FR2-A (deliberate change, requirement quoted in the 1.28 spec): a −58 dBFS "word" over a −67 dBFS room is
    /// below the −50 dBFS possible-speech line and no longer vetoes the drop (v1.11–1.27 kept "Then call Maria.").
    @Test func soundBelowMinus50DoesNotVetoTheDrop() async {
        let last = tone(1.0) + noise(0.3) + tone(0.5, amplitude: 60) + noise(1.2) + click + noise(0.25)
        let result = await run([(tone(1.0), .init(text: report)), (last, .init(text: "Send it. Then call Maria."))])
        #expect(result.text == "Send the report to Maria. Send it.")
    }

    // MARK: v1.28 FR3-A — the opening after a long silent lead-in

    /// Raza's step 2 (2026-11-04, f049157e, 33.4 s, ~20 s silent first): the silent chunks were emptied (FR2-A), yet the
    /// first chunk that held speech began with an invented sentence ("And I'll see you next time. Cold Start 1, …") —
    /// the opening was only ever judged in chunk 0, and inside its own chunk the speech starts < 1 s in (0.95 s).
    /// RED on 0faa887: the invented sentence is kept. GREEN: the text starts at "Cold start one".
    @Test func inventedOpeningAfterSilentChunksIsDropped() async {
        // v1.28 FR4-A: Groq's segments place the invented sentence inside the chunk's silent lead (0.0–0.9 s).
        let result = await run([(noise(3.0), .init(text: "Thank you.")), (noise(3.5), .init(text: "Dictate.")),
                                (noise(3.3), .init(text: "Thank you.")),
                                (noise(0.95) + tone(2.4), .init(text: "And I'll see you next time. Cold start one, this should begin on the first tap, as planned today.",
                                    segments: [.init(start: 0.0, end: 0.9, text: "And I'll see you next time."),
                                               .init(start: 0.95, end: 3.35, text: "Cold start one, this should begin on the first tap, as planned today.")]))])
        print("FR3-A LITERAL text=\"\(result.text)\" silent_chunks=\(result.droppedSilentChunks) opening_drops=\(result.droppedOpeningSentences)")
        #expect(result.text == "Cold start one, this should begin on the first tap, as planned today.")
    }

    /// Control: after the same silent lead-in, an honest opening (speech from 0.2 s into its chunk) is kept.
    @Test func honestOpeningAfterSilentChunksIsKept() async {
        let result = await run([(noise(3.0), .init(text: "Thank you.")), (noise(3.5), .init(text: "Dictate.")),
                                (noise(0.2) + tone(3.0), .init(text: "Cold start one. This should begin on the first tap."))])
        print("FR3-A CONTROL honest_opening text=\"\(result.text)\"")
        #expect(result.text == "Cold start one. This should begin on the first tap.")
    }

    // MARK: v1.28 FR4-A — the opening after a silent lead-in is judged on Groq's segment timestamps

    /// The FR3 stop-rule reviewer's honest case: after a silent lead-in the speech chunk has a 3.0 s lead (an arbitrary
    /// pause cut), so letter-count placement maps the honest "Cold start one." onto the lead. RED on 0051609: dropped.
    /// GREEN: its segment (3.0–4.2 s) overlaps speech → kept.
    @Test func honestOpeningAfterLongChunkLeadIsKept() async {
        let result = await run([(noise(3.0), .init(text: "Thank you.")), (noise(3.5), .init(text: "Dictate.")),
                                (noise(3.0) + tone(3.0), .init(text: "Cold start one. This should begin on the first tap.",
                                    segments: [.init(start: 3.0, end: 4.2, text: "Cold start one."),
                                               .init(start: 4.2, end: 6.0, text: "This should begin on the first tap.")]))])
        print("FR4-A LITERAL honest_long_lead text=\"\(result.text)\" silent_chunks=\(result.droppedSilentChunks) opening_drops=\(result.droppedOpeningSentences)")
        #expect(result.text == "Cold start one. This should begin on the first tap.")
    }

    /// v1.28 FR5-A: every chunk, chunk 0 included, asks Groq for `verbose_json` (segments + confidences).
    /// FR4 had chunk 0 on `json` (RED on 3c6aad8: `["json", "verbose_json", "verbose_json"]`).
    @Test func laterChunksAskForSegments() async {
        let transport = FormatTransport()
        let stt = GroqChunkedTranscriber(transport: transport, apiKey: { "test-key" }, prompt: "Politrace",
                                         fillerLeadIn: false, hedgeAfterMs: 60_000)
        let chunks = [tone(1.0), tone(1.2), tone(1.4)]
        for (index, samples) in chunks.enumerated() {
            await stt.submit(.init(index: index, samples: samples), isFinal: index == chunks.count - 1)?.value
        }
        _ = await stt.finish()
        let formats = await chunks.map { ScriptedTransport.key($0) }.asyncMap { await transport.formats[$0] ?? "none" }
        print("FR4-A LITERAL response_format=\(formats)")
        #expect(formats == ["verbose_json", "verbose_json", "verbose_json"])     // v1.28 FR5-A: every chunk (was json for chunk 0)
    }

    /// No segments (Apple, Scribe, a stub) after a silent lead-in: a general sentence is never dropped by letters.
    /// RED on 0051609: "Okay so." (letters inside the 2.0 s lead) dropped. GREEN: kept.
    @Test func noSegmentsAfterSilentLeadInKeepsGeneralSentence() async {
        let result = await run([(noise(3.0), .init(text: "Thank you.")), (noise(3.5), .init(text: "Dictate.")),
                                (noise(2.0) + tone(2.0), .init(text: "Okay so. Book the flight to Denver."))])
        print("FR4-A LITERAL no_segments_general text=\"\(result.text)\" opening_drops=\(result.droppedOpeningSentences)")
        #expect(result.text == "Okay so. Book the flight to Denver.")
    }

    /// No segments after a silent lead-in: a known artifact over the lead is still dropped (both trees).
    @Test func noSegmentsAfterSilentLeadInDropsArtifact() async {
        let result = await run([(noise(3.0), .init(text: "Thank you.")), (noise(3.5), .init(text: "Dictate.")),
                                (noise(2.0) + tone(2.0), .init(text: "Thank you. Book the flight to Denver."))])
        print("FR4-A LITERAL no_segments_artifact text=\"\(result.text)\" artifacts=\(result.droppedArtifacts)")
        #expect(result.text == "Book the flight to Denver.")
    }

    // MARK: v1.28 FR5 — Whisper's own confidence

    /// Room noise at −46 dBFS (above FR2-A's −50 dBFS possible-speech line, below the −40 dBFS speech line).
    private func room46(_ seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { $0.isMultiple(of: 2) ? 164 : -164 }
    }

    /// Raza's re-test 1 (2026-11-05 06:45:43, trace 97ee30ab.txt; built-in carried 17.8 s, silent ~15 s then
    /// "Cold start one…"): chunk 0 `Positives`, chunk 1 empty, chunk 2 `Let's see if you can start recording this
    /// recording.` (INVENTED over room noise), chunk 3 real. Confidences per FR5-C (chunk 2 p=0.82 lp=-1.3; chunk 3
    /// p=0.02 lp=-0.25); chunk 0's (p=0.7 lp=-1.2) are assumed (not recorded). RED on 3c6aad8: the invented sentence is
    /// kept. GREEN: only the real sentences.
    @Test func inventedSentenceOverRoomNoiseIsDroppedByConfidence() async {
        let result = await run([(noise(3.0), .init(text: "Positives", segments: [.init(start: 0, end: 2.9, text: "Positives", p: 0.7, lp: -1.2, cr: 0.8)])),
                                (noise(3.5), .init(text: "", segments: [])),
                                (room46(4.0), .init(text: "Let's see if you can start recording this recording.",
                                    segments: [.init(start: 0, end: 3.8, text: "Let's see if you can start recording this recording.", p: 0.82, lp: -1.3, cr: 1.1)])),
                                (tone(2.9), .init(text: "Cold start one. This should begin on the first tap.",
                                    segments: [.init(start: 0.1, end: 1.2, text: "Cold start one.", p: 0.02, lp: -0.25, cr: 0.9),
                                               .init(start: 1.2, end: 2.8, text: "This should begin on the first tap.", p: 0.02, lp: -0.25, cr: 1.0)]))])
        print("FR5 LITERAL transcriber_0645 text=\"\(result.text)\" silent_chunks=\(result.droppedSilentChunks)")
        #expect(result.text == "Cold start one. This should begin on the first tap.")
        print("FR5 LITERAL transcriber_0645 stt_dropped_segment_conf=\(result.droppedSegmentConf)")      // FR5-A field
        #expect(result.droppedSegmentConf == 2)
    }

    /// Control: a quiet but real sentence (p=0.3, a window ≥ −40 dBFS) is kept, even with a poor logprob.
    @Test func quietRealSentenceWithLoudWindowIsKept() async {
        let result = await run([(tone(2.2, amplitude: 600) + tone(0.4), .init(text: "Call Maria back.",
                                    segments: [.init(start: 0, end: 2.6, text: "Call Maria back.", p: 0.3, lp: -1.4, cr: 0.9)]))])
        print("FR5 CONTROL quiet_real text=\"\(result.text)\"")
        #expect(result.text == "Call Maria back.")
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

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}
