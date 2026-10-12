import Foundation
import Testing
import DictateCore

private actor CannedLowSpeechTransport: HTTPTransport {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let text = responses.removeFirst()
        let data = try JSONSerialization.data(withJSONObject: ["text": text])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Suite("LowSpeechSentenceGuard")
struct LowSpeechSentenceGuardTests {
    private let hallucination = "Hey, um, so. For the past, I'm going to go to the next question."

    @Test func dropsUnrelatedSentenceInLowSpeechChunk() {
        let result = LowSpeechSentenceGuard.filter(hallucination, speechRatio: 0.1,
            vocabulary: "TurnoutWatch, Limpar", nextText: "the launch is on Thursday with Maria")
        #expect(result.text == "Hey, um, so.")
        #expect(result.dropped == 1)
    }

    @Test func keepsWhenChunkHasSpeech() {
        let result = LowSpeechSentenceGuard.filter(hallucination, speechRatio: 0.6,
            vocabulary: "TurnoutWatch, Limpar", nextText: "the launch is on Thursday with Maria")
        #expect(result.text == hallucination)
        #expect(result.dropped == 0)
    }

    @Test func keepsWhenSentenceOverlapsNextChunk() {
        let result = LowSpeechSentenceGuard.filter("For the launch, I am going to the next question.", speechRatio: 0.1,
            vocabulary: "TurnoutWatch", nextText: "the launch is on Thursday")
        #expect(result.dropped == 0)
    }

    @Test func keepsWhenSentenceOverlapsVocabulary() {
        let result = LowSpeechSentenceGuard.filter("For Limpar, I am going to the next question.", speechRatio: 0.1,
            vocabulary: "TurnoutWatch, Limpar", nextText: "the launch is on Thursday")
        #expect(result.dropped == 0)
    }

    @Test func neverDropsEverything() {
        let result = LowSpeechSentenceGuard.filter("For the past, I am going to the next question.", speechRatio: 0.1,
            vocabulary: "TurnoutWatch", nextText: "the launch is on Thursday")
        #expect(result.dropped == 0)
    }

    @Test func lastChunkIsNeverFiltered() {
        let result = LowSpeechSentenceGuard.filter("For the past, I am going to the next question.", speechRatio: 0.1,
            vocabulary: "TurnoutWatch", nextText: nil)
        #expect(result.dropped == 0)
    }

    @Test func speechRatioOfZerosIsZero() {
        #expect(LowSpeechSentenceGuard.speechRatio(of: [Int16](repeating: 0, count: 48_000)) == 0)
    }

    @Test func lowSpeechGuardSwitchDefaultsToEnabled() {
        #expect(GroqChunkedTranscriber.lowSpeechGuardEnabled(environment: [:]))
        #expect(!GroqChunkedTranscriber.lowSpeechGuardEnabled(environment: ["DICTATE_LOW_SPEECH_GUARD": "0"]))
    }

    @Test func speechRatioOfToneAfterSilence() {
        let samples = noise(seconds: 1.5) + tone(seconds: 0.5, amplitude: 3_000)
        let ratio = LowSpeechSentenceGuard.speechRatio(of: samples)
        #expect((0.2...0.3).contains(ratio))
    }

    @Test func speechRatioOfMostlySpeechChunk() {
        let ratio = LowSpeechSentenceGuard.speechRatio(of: noise(seconds: 0.25) + tone(seconds: 1.75, amplitude: 3_000))
        #expect(ratio > 0.5)
    }

    @Test func chunkedTranscriberDropsLowSpeechSentence() async {
        let lowSpeech = tone(seconds: 0.4, amplitude: 3_000) + noise(seconds: 2.6)
        let speech = tone(seconds: 3, amplitude: 3_000)
        let guardedTransport = CannedLowSpeechTransport(responses: [hallucination, "the launch is on Thursday"])
        let guarded = GroqChunkedTranscriber(transport: guardedTransport, apiKey: { "test-key" },
            prompt: "TurnoutWatch, Limpar", fillerLeadIn: false, hedgeAfterMs: 60_000, lowSpeechGuard: true)
        if let task = guarded.submit(.init(index: 0, samples: lowSpeech), isFinal: false) { await task.value }
        if let task = guarded.submit(.init(index: 1, samples: speech), isFinal: true) { await task.value }
        let guardedResult = await guarded.finish()
        #expect(!guardedResult.text.contains("next question"))
        #expect(guardedResult.droppedLowSpeechSentences == 1)

        let unguardedTransport = CannedLowSpeechTransport(responses: [hallucination, "the launch is on Thursday"])
        let unguarded = GroqChunkedTranscriber(transport: unguardedTransport, apiKey: { "test-key" },
            prompt: "TurnoutWatch, Limpar", fillerLeadIn: false, hedgeAfterMs: 60_000, lowSpeechGuard: false)
        if let task = unguarded.submit(.init(index: 0, samples: lowSpeech), isFinal: false) { await task.value }
        if let task = unguarded.submit(.init(index: 1, samples: speech), isFinal: true) { await task.value }
        let unguardedResult = await unguarded.finish()
        #expect(unguardedResult.text.contains("next question"))
        #expect(unguardedResult.droppedLowSpeechSentences == 0)
    }

    private func noise(seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { index in index.isMultiple(of: 2) ? 15 : -15 }
    }

    private func tone(seconds: Double, amplitude: Int16) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { index in
            Int16((Double(amplitude) * sin(2 * .pi * 220 * Double(index) / 24_000)).rounded())
        }
    }
}
