import Foundation
import Security

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Same as `send`, plus ms from request start to the response's first
    /// byte when the transport can measure it.
    func sendTimed(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, Int?)
}

extension HTTPTransport {
    public func sendTimed(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, Int?) {
        let (data, response) = try await send(request)
        return (data, response, nil)
    }
}

/// Collects URLSessionTaskMetrics for one task.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { self.metrics = metrics }
    }
    var firstByteMs: Int? {
        lock.withLock {
            guard let t = metrics?.transactionMetrics.last, let start = t.fetchStartDate, let first = t.responseStartDate else { return nil }
            return Int(first.timeIntervalSince(start) * 1000)
        }
    }
}

public struct URLSessionTransport: HTTPTransport {
    /// One session per transport so keep-alive connections are reused: a fresh
    /// session per request paid a TLS handshake on every call.
    private let session: URLSession

    public init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func sendTimed(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, Int?) {
        let collector = MetricsCollector()
        let (data, response) = try await session.data(for: request, delegate: collector)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // didFinishCollecting can land just after data(for:) returns.
        for _ in 0..<20 where collector.firstByteMs == nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        return (data, http, collector.firstByteMs)
    }
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case missingKey, auth, server(Int), client(Int), network(String), decode
    case rejected(String)

    public var logReason: String {
        switch self {
        case .missingKey: return "missing_key"
        case .auth: return "auth"
        case .server(let status): return "server_\(status)"
        case .client(let status): return "client_\(status)"
        case .network(let code):
            return "network_" + String(code.map { $0.isWhitespace ? "_" : $0 })
        case .decode: return "decode"
        case .rejected(let reason): return "rejected_\(reason)"
        }
    }
}

public struct TranscriptionClient: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let model = "gpt-4o-transcribe"
    public let transport: HTTPTransport
    public let apiKey: @Sendable () throws -> String

    public static let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    /// Overridable per instance (Groq whisper-large-v3-turbo for the bench).
    public var endpointURL: URL = TranscriptionClient.endpoint
    public var modelName: String = TranscriptionClient.model

    public init(transport: HTTPTransport, apiKey: @escaping @Sendable () throws -> String) {
        self.transport = transport
        self.apiKey = apiKey
    }

    public func makeRequest(wav: Data, prompt: String, apiKey: String, boundary: String,
                            includeEmptyPrompt: Bool = false) -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        func part(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        part("model", modelName)
        part("response_format", "json")
        part("language", "en")
        if includeEmptyPrompt || !prompt.isEmpty { part("prompt", prompt) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    public func transcribe(wav: Data, prompt: String) async throws -> String {
        let key: String
        do { key = try apiKey().trimmingCharacters(in: .whitespacesAndNewlines) }
        catch { throw TranscriptionError.missingKey }
        guard !key.isEmpty else { throw TranscriptionError.missingKey }
        let request = makeRequest(wav: wav, prompt: prompt, apiKey: key, boundary: "dictate-\(UUID().uuidString)")
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.send(request) }
        catch let error as TranscriptionError { throw error }
        catch let error as URLError {
            let code = error.code == .timedOut ? "timedOut" : String(error.code.rawValue)
            throw TranscriptionError.network(code)
        }
        catch { throw TranscriptionError.network("transport") }
        let (data, response) = result
        switch response.statusCode {
        case 200...299: break
        case 401, 403: throw TranscriptionError.auth
        case 500...599: throw TranscriptionError.server(response.statusCode)
        default: throw TranscriptionError.client(response.statusCode)
        }
        struct Transcript: Decodable { let text: String }
        guard let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else {
            throw TranscriptionError.decode
        }
        return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum KeychainAPIKey {
    public static func read(service: String = "openai-api", account: String = "razakhan") throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw TranscriptionError.missingKey }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionError.missingKey }
        return key
    }
}
