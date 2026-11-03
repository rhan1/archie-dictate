import Foundation
import Testing
@testable import DictateCore

/// Groq cleanup as observed: empty dictation text comes back as a stray token ("x" → ratio rejection); real text is
/// cleaned. Records every input.
private actor AutoCleanTransport: HTTPTransport {
    private(set) var inputs: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let user = (body["messages"] as! [[String: String]]).last!["content"]!
        let text = user.components(separatedBy: "<dictation>").last?.components(separatedBy: "</dictation>").first ?? ""
        inputs.append(text)
        let content = text.trimmingCharacters(in: .whitespaces).isEmpty ? "x"
            : text.replacingOccurrences(of: "Cold Start 1, this should begin on the 1st. Tap.", with: "Cold start one. This should begin on the first tap.")
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        return (data, HTTPURLResponse(url: TranscriptCleaner.groqEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// v1.28 FR3-B (Raza's step 2, f049157e: `chunks=9 stt_dropped_silent_chunk=6`, `cleanup_mode=incremental_fallback
/// fallback_reason=mid_rejected_ratio` → raw paste): chunks emptied as silent were still offered to the incremental
/// cleaner as an EMPTY mid, whose rejection disabled the incremental path. RED on 0faa887: an empty cleaner input and
/// `mid_rejected_ratio`. GREEN: no empty input; the real text is cleaned incrementally.
@Suite("V128EmptyMid")
struct V128EmptyMidTests {
    @Test func emptiedChunksAreNeverOfferedToTheCleaner() async throws {
        let transport = AutoCleanTransport()
        var cleaner = TranscriptCleaner(transport: transport, vocabulary: "", apiKey: { "hermetic-key" })
        cleaner.hintsSentence = ""
        let incremental = IncrementalCleaner(cleaner: cleaner, finalIncludeExamples: false,
                                             quotaProvider: { GroqQuota() })
        let texts = Array(repeating: "", count: 6) + ["Cold Start 1, this should begin on the 1st. Tap.", "", ""]
        for (index, text) in texts.enumerated() {
            incremental.append(index: index, text: text)
            await incremental.waitForPending()
        }
        let result = await incremental.finish(totalChunks: texts.count)
        let inputs = await transport.inputs
        let empty = inputs.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        print("FR3-B LITERAL mode=\(result.mode) fallback_reason=\(result.fallbackReason ?? "none") empty_cleaner_inputs=\(empty) calls=\(inputs.count) text=\"\(result.text ?? "nil")\"")
        #expect(empty == 0)
        #expect(result.fallbackReason == nil)
        #expect(result.text == "Cold start one. This should begin on the first tap.")
    }
}
