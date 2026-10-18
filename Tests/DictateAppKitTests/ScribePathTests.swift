import Foundation
import Testing
@testable import DictateAppKit
import DictateCore

/// v1.16: a chunk set rescued by ElevenLabs Scribe reports `path=scribe-chunked`; a failed set still lands on Apple.
@Suite("Scribe path (v1.16)")
struct ScribePathTests {
    struct Chunks: EngineChunkSession {
        let result: GroqChunkedTranscriber.Result
        func append(_ samples: [Int16]) {}
        func finish(at: DispatchTime) async -> GroqChunkedTranscriber.Result { result }
        func cancel() {}
    }
    struct Apple: EngineAppleSession {
        let text: String
        func start() async throws {}
        func append(_ samples: [Int16]) {}
        func finish() async throws -> String { text }
        func cancel() {}
    }
    static func result(text: String, failed: Int, scribe: Int = 0, noKey: Bool = false) -> GroqChunkedTranscriber.Result {
        var r = GroqChunkedTranscriber.Result(text: text, chunks: 1, rejoins: 0, failedCount: failed, lastChunkMs: 1, sttMs: 1,
                                              calls: [], hedges: 0, hedgeWins: 0, rateLimits: nil)
        r.scribeChunks = scribe
        r.scribeNoKey = noKey
        return r
    }
    let policy = EnginePolicy()

    @Test func scribeRescuedChunksReportScribePath() async {
        let stt = await policy.transcribe(apple: Apple(text: "apple words"),
                                          chunked: Chunks(result: Self.result(text: "scribe words", failed: 0, scribe: 1)),
                                          at: .now())
        #expect(stt.path == "scribe-chunked")
        #expect((try? stt.result.get()) == "scribe words")
    }
    @Test func groqOnlyKeepsGroqPath() async {
        let stt = await policy.transcribe(apple: Apple(text: "apple words"),
                                          chunked: Chunks(result: Self.result(text: "groq words", failed: 0)), at: .now())
        #expect(stt.path == "groq-chunked")
    }
    @Test func scribeFailureOrNoKeyFallsToApple() async {
        let stt = await policy.transcribe(apple: Apple(text: "apple words"),
                                          chunked: Chunks(result: Self.result(text: "", failed: 1, noKey: true)), at: .now())
        #expect(stt.path == "apple")
        #expect((try? stt.result.get()) == "apple words")
        #expect(stt.joined?.scribeNoKey == true)
    }
}
