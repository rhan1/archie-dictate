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
/// v1.19 (ST1): a streaming provider (Deepgram) — provider-neutral result, see `StreamingSTTResult`.
typealias EngineStreamingSession = StreamingSTTSession
extension AppleTranscriber: EngineAppleSession {}
extension GroqChunkedTranscriber: EngineChunkSession {}

extension EnginePolicy {
    struct STTResult {
        let result: Result<String, Error>
        let path: String
        let joined: GroqChunkedTranscriber.Result?
        let appleFinal: Task<String?, Never>
        /// v1.19: the streaming session's own result (also when it was replaced by the whole-WAV recovery).
        var streamed: StreamingSTTResult? = nil
    }

    /// Paths whose live segments fed this session's IncrementalCleaner: both reach the same
    /// incremental/single cleanup finalization and the same insertion.
    static func isIncrementalPath(_ path: String) -> Bool {
        path == "groq-chunked" || path == "deepgram-streaming"
    }

    func transcribe(apple: EngineAppleSession?, chunked: EngineChunkSession?, at: DispatchTime) async -> STTResult {
        let appleFinal = Task { try? await apple?.finish() }
        let joined = usesGroqSTT ? await chunked?.finish(at: at) : nil
        if let joined, joined.failedCount == 0, !joined.text.isEmpty {
            return STTResult(result: .success(joined.text), path: joined.scribeChunks > 0 ? "scribe-chunked" : "groq-chunked",
                             joined: joined, appleFinal: appleFinal)
        }
        if let text = await appleFinal.value, !text.isEmpty {
            return STTResult(result: .success(text), path: "apple", joined: joined, appleFinal: appleFinal)
        }
        return STTResult(result: .failure(TranscriptionError.rejected("no_stt")), path: "apple", joined: joined,
                         appleFinal: appleFinal)
    }

    /// v1.19 (ST1) streaming finalization. A complete stream with text is the transcript
    /// (`deepgram-streaming`). An incomplete one (failure at ANY point, including after stop) first
    /// runs `onIncomplete` (the host cancels this session's incremental cleanup), then exactly ONE
    /// whole-WAV Groq transcription of the full recording (`groq-whole`) when Groq STT is eligible.
    /// If that fails too, the existing recovery applies: Apple's final, else `no_stt`.
    /// Never claims a guaranteed transcription. Logs counts/reasons only.
    func transcribe(apple: EngineAppleSession?, streaming: EngineStreamingSession, at: DispatchTime,
                    wholeWAV: @Sendable () async throws -> String,
                    onIncomplete: @Sendable (String) -> Void) async -> STTResult {
        let appleFinal = Task { try? await apple?.finish() }
        let streamed = await streaming.finish(at: at)
        if streamed.complete, !streamed.text.isEmpty {
            return STTResult(result: .success(streamed.text), path: "deepgram-streaming", joined: nil,
                             appleFinal: appleFinal, streamed: streamed)
        }
        if !streamed.complete {
            let reason = streamed.diagnostics.failureReason ?? "incomplete"
            onIncomplete(reason)
            if usesGroqSTT {
                AppController.note("stt_fallback=groq reason=\(reason)")
                if let text = try? await wholeWAV(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return STTResult(result: .success(text), path: "groq-whole", joined: nil,
                                     appleFinal: appleFinal, streamed: streamed)
                }
            } else {
                AppController.note("stt_fallback=apple reason=\(reason) groq=ineligible")
            }
        }
        if let text = await appleFinal.value, !text.isEmpty {
            return STTResult(result: .success(text), path: "apple", joined: nil, appleFinal: appleFinal, streamed: streamed)
        }
        return STTResult(result: .failure(TranscriptionError.rejected("no_stt")), path: "apple", joined: nil,
                         appleFinal: appleFinal, streamed: streamed)
    }
}
