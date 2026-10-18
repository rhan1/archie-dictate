import Foundation

public struct ScribeClient: Sendable {
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    public static let model = "scribe_v1"
    public static let timeout: TimeInterval = 30

    public let transport: HTTPTransport
    public let apiKey: @Sendable () throws -> String
    public var endpointURL: URL = ScribeClient.endpoint
    public var modelID: String = ScribeClient.model

    public init(transport: HTTPTransport, apiKey: @escaping @Sendable () throws -> String) {
        self.transport = transport
        self.apiKey = apiKey
    }

    public func makeRequest(wav: Data, apiKey: String, boundary: String = "dictate-\(UUID().uuidString)") -> URLRequest {
        var request = URLRequest(url: endpointURL, timeoutInterval: Self.timeout)
        request.timeoutInterval = Self.timeout
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ string: String) { body.append(contentsOf: string.utf8) }
        func part(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        part("model_id", modelID)
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    public func transcribe(wav: Data) async throws -> String {
        let key: String
        do { key = try apiKey().trimmingCharacters(in: .whitespacesAndNewlines) }
        catch { throw TranscriptionError.missingKey }
        guard !key.isEmpty else { throw TranscriptionError.missingKey }
        let request = makeRequest(wav: wav, apiKey: key, boundary: "dictate-\(UUID().uuidString)")
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
        let trimmed = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.decode
        }
        return trimmed
    }
}
