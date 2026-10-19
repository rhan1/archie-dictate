import Foundation
import DictateCore

protocol EngineAppleSession: Sendable {
    func start() async throws
    func append(_ samples: [Int16])
    func finish() async throws -> String
    func cancel()
}
protocol EngineChunkSession: Sendable {
    func append(_ samples: [Int16])
    func finish(at: DispatchTime) async -> GroqChunkedTranscriber.Result
    func cancel()
}
extension AppleTranscriber: EngineAppleSession {}
extension GroqChunkedTranscriber: EngineChunkSession {}
extension DeepgramStreamingTranscriber: EngineChunkSession {}

extension EnginePolicy {
    struct STTResult {
        let result: Result<String, Error>
        let path: String
        let joined: GroqChunkedTranscriber.Result?
        let appleFinal: Task<String?, Never>
    }

    func transcribe(apple: EngineAppleSession?, chunked: EngineChunkSession?, at: DispatchTime) async -> STTResult {
        let appleFinal = Task { try? await apple?.finish() }
        let streaming = chunked as? DeepgramStreamingTranscriber
        let joined = (usesGroqSTT || streaming != nil) ? await chunked?.finish(at: at) : nil
        if let joined, joined.failedCount == 0, !joined.text.isEmpty {
            let path = streaming.map { $0.fallbackReason == nil ? "deepgram-streaming" : "groq-whole" }
                ?? (joined.scribeChunks > 0 ? "scribe-chunked" : "groq-chunked")
            return STTResult(result: .success(joined.text), path: path,
                             joined: joined, appleFinal: appleFinal)
        }
        if let text = await appleFinal.value, !text.isEmpty {
            return STTResult(result: .success(text), path: "apple", joined: joined, appleFinal: appleFinal)
        }
        return STTResult(result: .failure(TranscriptionError.rejected("no_stt")), path: "apple", joined: joined,
                         appleFinal: appleFinal)
    }
}
