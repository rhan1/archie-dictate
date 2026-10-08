import Foundation

/// Anything that can run the cleanup pass (local Ollama or OpenAI).
public protocol TextCleaner: Sendable {
    var model: String { get }
    func cleanWithStats(_ text: String) async throws -> (text: String, stats: TranscriptCleaner.Stats)
    func warmUp() async
}

extension TranscriptCleaner: TextCleaner {}

/// v1.1 G7: the cleanup pass on a local Ollama model — no network round-trip.
/// Same system prompt as the cloud pass, temperature 0, model kept loaded 30 min.
public struct OllamaCleaner: TextCleaner {
    public static let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
    /// G7 (2026-10-09): llama3.2:3b 9/10 quality, p50 857 ms; qwen2.5:3b 7/10, 915 ms.
    public static let defaultModel = "llama3.2:3b-instruct-q4_K_M"
    public static let keepAlive = "30m"

    public let transport: HTTPTransport
    public let model: String
    public let vocabulary: String
    public let deadline: TimeInterval

    public init(transport: HTTPTransport, model: String = OllamaCleaner.defaultModel, vocabulary: String,
                deadline: TimeInterval = 1.5) {
        self.transport = transport
        self.model = model
        self.vocabulary = vocabulary
        self.deadline = deadline
    }

    public func systemPrompt() -> String {
        vocabulary.isEmpty ? TranscriptCleaner.instructions : TranscriptCleaner.instructions + "\nVocabulary: " + vocabulary
    }

    public func makeRequest(text: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = deadline
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "keep_alive": Self.keepAlive,
            "options": ["temperature": 0],
            "messages": TranscriptCleaner.messages(system: systemPrompt(), text: text),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Loads the model (one tiny request) so the first dictation doesn't pay it.
    public func warmUp() async {
        var request = makeRequest(text: "ok")
        request.timeoutInterval = 30
        _ = try? await transport.send(request)
    }

    public func cleanWithStats(_ text: String) async throws -> (text: String, stats: TranscriptCleaner.Stats) {
        let data: Data
        let response: HTTPURLResponse
        var stats = TranscriptCleaner.Stats()
        do {
            (data, response, stats.firstByteMs) = try await transport.sendTimed(makeRequest(text: text))
        } catch let error as URLError {
            throw TranscriptionError.network(error.code == .timedOut ? "timedOut" : "\(error.code.rawValue)")
        } catch {
            throw TranscriptionError.network("transport")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw response.statusCode >= 500 ? TranscriptionError.server(response.statusCode) : TranscriptionError.client(response.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw TranscriptionError.decode }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw TranscriptionError.decode }
        stats.completionTokens = json["eval_count"] as? Int
        return (cleaned, stats)
    }
}
