import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
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
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case missingKey, auth, server(Int), client(Int), network(String), decode

    public var logReason: String {
        switch self {
        case .missingKey: return "missing_key"
        case .auth: return "auth"
        case .server(let status): return "server_\(status)"
        case .client(let status): return "client_\(status)"
        case .network(let code):
            return "network_" + String(code.map { $0.isWhitespace ? "_" : $0 })
        case .decode: return "decode"
        }
    }
}

public struct TranscriptionClient: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let model = "gpt-4o-transcribe"
    public let transport: HTTPTransport
    public let apiKey: @Sendable () throws -> String

    public init(transport: HTTPTransport, apiKey: @escaping @Sendable () throws -> String) {
        self.transport = transport
        self.apiKey = apiKey
    }

    public func makeRequest(wav: Data, prompt: String, apiKey: String, boundary: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        func part(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        part("model", Self.model)
        part("response_format", "json")
        part("language", "en")
        if !prompt.isEmpty { part("prompt", prompt) }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw TranscriptionError.missingKey }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !key.isEmpty else { throw TranscriptionError.missingKey }
        return key
    }
}
