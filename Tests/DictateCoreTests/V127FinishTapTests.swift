import Foundation
import Testing
@testable import DictateCore

/// Models Whisper (whisper-large-v3-turbo on Groq) as observed on 2026-11-03 03:13 and 2026-10-13: a request
/// whose audio is near-silence (room noise, a key click, a breath) comes back with words from its PROMPT
/// ("Dictate.", "Thank you.") when a prompt is sent, and empty without one. Real speech comes back as
/// itself either way. The stub decides only from the request (its audio and its prompt field):
/// - audio longer than 1.5 s → the spoken sentence of the fixture ("Please send the report.");
/// - short audio with ≥ 0.3 s of speech-level windows → "yes.";
/// - short audio without speech → "Dictate." when the prompt is non-empty, "" when it is empty.
/// It also records every request's duration and prompt, so tests read what was sent.
actor WhisperPromptEchoStub: HTTPTransport {
    struct Sent: Sendable { let seconds: Double; let prompt: String }
    private(set) var sent: [Sent] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody ?? Data()
        let prompt = Self.field("prompt", in: body)
        let samples = Self.pcm(in: body)
        let seconds = Double(samples.count) / 16_000
        sent.append(Sent(seconds: seconds, prompt: prompt))
        let loud = stride(from: 0, to: samples.count, by: 800).filter { start in
            let window = samples[start..<min(samples.count, start + 800)]
            let rms = (window.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(window.count)).squareRoot() / 32_768
            return rms >= 0.05
        }.count
        let text: String
        if seconds > 1.5 { text = "Please send the report." }
        else if loud >= 6 { text = "yes." }
        else { text = prompt.isEmpty ? "" : "Dictate." }
        let data = try JSONSerialization.data(withJSONObject: ["text": text])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    static func field(_ name: String, in body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        guard let range = text.range(of: "name=\"\(name)\"\r\n\r\n") else { return "<absent>" }
        let rest = text[range.upperBound...]
        return String(rest[..<(rest.range(of: "\r\n--")?.lowerBound ?? rest.endIndex)])
    }
    static func pcm(in body: Data) -> [Int16] {
        guard let riff = body.range(of: Data("RIFF".utf8))?.lowerBound else { return [] }
        let start = riff + 44
        var out: [Int16] = []
        var i = start
        while i + 1 < body.count {
            if body[i] == 0x0D, i + 1 < body.count, body[i + 1] == 0x0A,
               body[i...].starts(with: Data("\r\n--".utf8)) { break }
            out.append(Int16(bitPattern: UInt16(body[i]) | UInt16(body[i + 1]) << 8))
            i += 2
        }
        return out
    }
}

/// v1.27 B2: "random words get added at the end … it added 'Dictate'" (Raza, 10-13 and 11-03). The final chunk
/// after the finish tap is room noise and the key click; with the filler lead-in + vocabulary + previous text as
/// its prompt, Whisper answers with prompt words. Synthesised fixtures only (no recording).
@Suite("V127FinishTap")
struct V127FinishTapTests {
    static let rate = 24_000
    static let vocabulary = "Politrace, Limpar, DB99, Raza, Archie, Jarvis, Codex, agy, Warp, Claude, Fable, Opus, Sonnet, Groq, Ollama, Dictate"
    /// Spoken sentence: a 220 Hz tone at speech level.
    static func speech(_ seconds: Double, amplitude: Double = 8_000) -> [Int16] {
        (0..<Int(seconds * Double(rate))).map { Int16(amplitude * sin(Double($0) * 2 * .pi * 220 / Double(rate))) }
    }
    /// The room before the first word (a real dictation starts in silence; the chunker's floor calibrates on it).
    static let lead = noise(0.3, seed: 3)
    /// Room noise ≈ −61 dBFS, deterministic.
    static func noise(_ seconds: Double, seed: Int = 7) -> [Int16] {
        (0..<Int(seconds * Double(rate))).map { i in
            var x = UInt64(truncatingIfNeeded: i &+ seed &* 1_000_003) &* 0x9E37_79B9_7F4A_7C15
            x ^= x >> 29; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 32
            return Int16(Int(x % 101) - 50)
        }
    }
    /// The finish tap as a microphone hears it: key press and release transients over ~150 ms of mechanical
    /// rattle, ending the recording. Its three 50 ms windows are each speech-like (≥ −40 dBFS), i.e. a
    /// "speech-like run" to v1.11's edge guard — which is why that guard kept "Dictate." tonight
    /// (`stt_dropped_artifact=0`). A lone 30 ms click (one window) would already be dropped by v1.11.
    static func click() -> [Int16] {
        (0..<3_600).map { i in
            var x = UInt64(truncatingIfNeeded: i &+ 99) &* 0x9E37_79B9_7F4A_7C15
            x ^= x >> 29; x &*= 0xBF58_476D_1CE4_E5B9; x ^= x >> 32
            let unit = Double(Int(x % 2_001) - 1_000) / 1_000
            let press = 12_000 * exp(-Double(i) / 150), release = i >= 2_000 ? 9_000 * exp(-Double(i - 2_000) / 150) : 0
            return Int16(max(-32_767, min(32_767, unit * (800 + press + release))))
        }
    }

    struct Run { let text: String; let sent: [WhisperPromptEchoStub.Sent]; let result: GroqChunkedTranscriber.Result }

    static func transcribe(_ pcm: [Int16]) async -> Run {
        let stub = WhisperPromptEchoStub()
        let transcriber = GroqChunkedTranscriber(transport: stub, apiKey: { "fixture" }, prompt: vocabulary)
        for start in stride(from: 0, to: pcm.count, by: 2_400) { transcriber.append(Array(pcm[start..<min(pcm.count, start + 2_400)])) }
        let result = await transcriber.finish()
        return Run(text: result.text, sent: await stub.sent, result: result)
    }
    static func promptKind(_ prompt: String) -> String {
        prompt == "<absent>" ? "absent" : prompt.isEmpty ? "none" : prompt.hasPrefix(GroqChunkedTranscriber.fillerLeadIn) ? "full" : "partial"
    }
    static func literal(_ name: String, _ run: Run) -> String {
        let finals = run.sent.sorted { $0.seconds > $1.seconds }.dropFirst().map { "final_s=\(String(format: "%.2f", $0.seconds)) prompt=\(promptKind($0.prompt))" }
        let r = run.result
        return "\(name) text=\"\(run.text)\" requests=\(run.sent.count) \(finals.joined(separator: " ")) stt_dropped_silent_chunk=\(r.droppedSilentChunks) stt_dropped_artifact=\(r.droppedArtifacts) stt_dropped_tail=\(r.droppedTailSentences) stt_dropped_click_chunk=\(r.droppedClickChunks) call_prompts=\(r.calls.map { "\($0.index):\($0.prompt)" }.joined(separator: ","))"
    }

    // Speech (3.4 s) → 0.6 s of room noise → the click. RED on 55cb366: "Please send the report. Dictate."
    @Test func clickOnlyFinalChunkAddsNoWords() async {
        let run = await Self.transcribe(Self.lead + Self.speech(3.4) + Self.noise(0.6) + Self.click())
        print("B2 LITERAL click_only \(Self.literal("click_only", run))")
        #expect(run.text == "Please send the report.")
        #expect(run.sent.count == 1)                                   // the click chunk is never sent
        #expect(run.result.droppedClickChunks == 1)
    }

    // A short final chunk with a soft breath first (a speech-like window before the click): sent, with NO prompt.
    @Test func shortFinalChunkIsSentWithoutAPrompt() async {
        let run = await Self.transcribe(Self.lead + Self.speech(3.4) + Self.noise(0.3) + Self.speech(0.1, amplitude: 600)
                                        + Self.noise(0.4, seed: 11) + Self.click())
        print("B2 LITERAL short_final \(Self.literal("short_final", run))")
        #expect(run.text == "Please send the report.")
        #expect(run.sent.count == 2 && run.sent.contains { Self.promptKind($0.prompt) == "none" })
        #expect(run.result.droppedClickChunks == 0 && run.result.calls.contains { $0.isFinal && $0.prompt == "none" })
    }

    // Controls.
    @Test func longFinalChunkKeepsTheFullPrompt() async {
        let run = await Self.transcribe(Self.lead + Self.speech(3.4) + Self.noise(0.3) + Self.speech(2.5))
        print("B2 LITERAL long_final \(Self.literal("long_final", run))")
        #expect(run.sent.count == 2)
        let final = run.sent.max { $0.seconds < $1.seconds }
        #expect(final.map { Self.promptKind($0.prompt) } == "full")
        #expect(final?.prompt.contains(Self.vocabulary) == true)
        #expect(run.result.calls.contains { $0.isFinal && $0.prompt == "full" })
        #expect(run.text == "Please send the report. Please send the report.")
    }

    @Test func shortFinalChunkWithSpeechIsStillTranscribed() async {
        let run = await Self.transcribe(Self.lead + Self.speech(3.4) + Self.noise(0.3) + Self.speech(0.8))
        print("B2 LITERAL short_speech \(Self.literal("short_speech", run))")
        #expect(run.sent.count == 2)
        #expect(run.result.droppedClickChunks == 0 && run.result.calls.contains { $0.isFinal && $0.prompt == "none" })
        #expect(run.text == "Please send the report. yes.")
    }
}
