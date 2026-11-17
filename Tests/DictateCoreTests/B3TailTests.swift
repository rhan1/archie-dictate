import Foundation
import Testing
import DictateCore

/// Groq by WAV data size (each chunk a different length), `verbose_json` with segments. No network.
private actor B3TailTransport: HTTPTransport {
    struct Reply: Sendable { let text: String; let segment: (Double, Double, Double, Double, Double)? }
    private let replies: [Int: Reply]
    init(_ replies: [Int: Reply]) { self.replies = replies }
    static func key(_ samples: [Int16]) -> Int { (samples.count * 2 / 3) * 2 }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody!
        let riff = body.range(of: Data("RIFF".utf8))!.lowerBound
        let size = (0..<4).reduce(0) { $0 | Int(body[riff + 40 + $1]) << (8 * $1) }
        guard let reply = replies[size] else {
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        var json: [String: Any] = ["text": reply.text]
        if let s = reply.segment {
            json["segments"] = [["id": 0, "start": s.0, "end": s.1, "text": " " + reply.text,
                                 "no_speech_prob": s.2, "avg_logprob": s.3, "compression_ratio": s.4]]
        }
        return (try JSONSerialization.data(withJSONObject: json),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// 62.7.1 B3 F4 (trace c2e38997, live 62.7.0 / b5f764b, Mac mic): a 0.74 s final tail with no speech
/// came back "Thank you." and was pasted. Real Mac-mic audio: Raza's question recorded on the MacBook
/// microphone (gitignored voice fixture, never committed); its last 0.9 s is room noise after his last word.
@Suite("B3TailTests", .serialized)
struct B3TailTests {
    static let fixture = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Projects/dictate/tools/fixtures/voice/raza-question-macbook.wav")
    static var present: Bool { FileManager.default.fileExists(atPath: fixture.path) }

    /// The recording at its own level (peak -25.2 dBFS), or scaled to `peakDBFS` (the incident's
    /// timeline measured peak_dbfs=-8.3: Raza spoke loudly, so the room tail sat well above the floor).
    static func samples(peakDBFS: Double? = nil) throws -> [Int16] {
        let data = try Data(contentsOf: fixture)
        let start = data.range(of: Data("data".utf8))!.upperBound + 4
        let raw = stride(from: start, to: data.count - 1, by: 2).map { Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8) }
        guard let peakDBFS, let peak = raw.map({ abs(Int($0)) }).max(), peak > 0 else { return raw }
        let gain = pow(10, peakDBFS / 20) * 32_768 / Double(peak)
        return raw.map { Int16(clamping: Int((Double($0) * gain).rounded())) }
    }

    fileprivate func run(_ chunks: [([Int16], B3TailTransport.Reply)]) async -> GroqChunkedTranscriber.Result {
        var replies: [Int: B3TailTransport.Reply] = [:]
        for (samples, reply) in chunks { replies[B3TailTransport.key(samples)] = reply }
        let stt = GroqChunkedTranscriber(transport: B3TailTransport(replies), apiKey: { "test-key" }, prompt: "Politrace",
                                         fillerLeadIn: false, hedgeAfterMs: 60_000)
        for (index, chunk) in chunks.enumerated() {
            await stt.submit(.init(index: index, samples: chunk.0), isFinal: index == chunks.count - 1)?.value
        }
        return await stt.finish()
    }

    @Test(.enabled(if: B3TailTests.present)) func silentShortTailThankYouIsNotPasted() async throws {
        let all = try Self.samples(peakDBFS: -8.3)
        let tail = Array(all.suffix(21_600))                       // 0.90 s of the Mac mic's room after the last word
        let speech = Array(all.prefix(all.count - tail.count))
        let question = "Can you check whether the build passed?"
        let result = await run([(speech, .init(text: question, segment: nil)),
                                (tail, .init(text: "Thank you.", segment: (0.00, 0.74, 0.00, -0.54, 0.58)))])
        let pasted = result.text.contains("Thank you")
        print("B3 \(pasted ? "RED" : "GREEN") tail_thank_you_pasted=\(pasted ? 1 : 0) tail_s=0.90 peak_dbfs=-8.3 dropped_artifact=\(result.droppedArtifacts) text_chars=\(result.text.count)")
        #expect(!pasted)
        #expect(result.text == question)
    }

    /// The same level; a short final tail that is a real word (not a silence phrase) is kept.
    @Test(.enabled(if: B3TailTests.present)) func shortRealFinalWordIsKept() async throws {
        let all = try Self.samples(peakDBFS: -8.3)
        // His last spoken word region (windows 82–100 at 50 ms, -37…-44 dBFS on the Mac mic), 0.95 s.
        let word = Array(all[(82 * 1_200)..<(82 * 1_200 + 22_800)])
        let speech = Array(all.prefix(82 * 1_200))
        for said in ["Send it now.", "Thank you."] {   // a real spoken "Thank you." at speech level is kept too (Fable read F1)
            let result = await run([(speech, .init(text: "Can you check whether the build passed?", segment: nil)),
                                    (word, .init(text: said, segment: (0.00, 0.80, 0.02, -0.30, 0.60)))])
            let kept = result.text.hasSuffix(said)
            print("B3 GREEN short_real_final_word_kept=\(kept ? 1 : 0) said=\"\(said)\" word_s=0.95 text_chars=\(result.text.count)")
            #expect(kept)
        }
    }
}

extension B3TailTests {
    /// The existing silent-chunk drop (no possible-speech window) still covers a quiet Mac-mic tail.
    @Test(.enabled(if: B3TailTests.present)) func quietRoomTailStillDroppedAsSilent() async throws {
        let all = try Self.samples()
        let tail = Array(all.suffix(21_600))
        let result = await run([(Array(all.prefix(all.count - tail.count)), .init(text: "Check the build.", segment: nil)),
                                (tail, .init(text: "Okay.", segment: nil))])
        print("B3 GREEN quiet_tail_silent_dropped=\(result.text == "Check the build." ? 1 : 0) silent_chunks=\(result.droppedSilentChunks)")
        #expect(result.text == "Check the build." && result.droppedSilentChunks == 1)
    }
}

/// Committed, always-run twin of the fixture tests (Codex read F3): synthetic levels matching the incident —
/// loud speech (−15 dBFS RMS) then a 0.9 s tail at −34 dBFS, above the −40 dBFS absolute speech line.
extension B3TailTests {
    static func tone(_ seconds: Double, amplitude: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { Int16((amplitude * sin(2 * .pi * 220 * Double($0) / 24_000)).rounded()) }
    }
    @Test func syntheticLoudRoomTailThankYouIsNotPasted() async {
        let speech = Self.tone(2.0, amplitude: 8_000), tail = Self.tone(0.9, amplitude: 900)
        let result = await run([(speech, .init(text: "Check the build.", segment: nil)),
                                (tail, .init(text: "Thank you.", segment: (0.00, 0.74, 0.00, -0.54, 0.58)))])
        let pasted = result.text.contains("Thank you")
        print("B3 \(pasted ? "RED" : "GREEN") synthetic_tail_thank_you_pasted=\(pasted ? 1 : 0) tail_dbfs=-34 speech_dbfs=-15")
        #expect(!pasted)
    }
    @Test func syntheticSpokenThankYouIsKept() async {
        let speech = Self.tone(2.0, amplitude: 8_000), said = Self.tone(0.9, amplitude: 6_000)
        let result = await run([(speech, .init(text: "Check the build.", segment: nil)),
                                (said, .init(text: "Thank you.", segment: (0.00, 0.80, 0.02, -0.30, 0.60)))])
        let kept = result.text == "Check the build. Thank you."
        print("B3 GREEN synthetic_spoken_thank_you_kept=\(kept ? 1 : 0)")
        #expect(kept)
    }
}
