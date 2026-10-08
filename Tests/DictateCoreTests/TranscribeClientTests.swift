import Foundation
import Testing
import DictateCore

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequest: URLRequest?
    private let response: HTTPURLResponse
    private let data: Data
    private let error: Error?

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }

    init(status: Int = 200, body: String = #"{"text":"hello"}"#, error: Error? = nil) {
        response = HTTPURLResponse(url: TranscriptionClient.endpoint, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        data = Data(body.utf8)
        self.error = error
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequest = request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        if let error { throw error }
        return (data, response)
    }
}

private enum FakeFailure: Error { case unavailable }

@Suite("TranscriptionClient")
struct TranscribeClientTests {
    private func client(_ transport: FakeTransport = FakeTransport()) -> TranscriptionClient {
        TranscriptionClient(transport: transport, apiKey: { "test-key" })
    }

    @Test func multipartContainsRequiredPartsAndBytes() throws {
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0xff, 0x80])
        let request = client().makeRequest(wav: wav, prompt: "Acme Corp, PostgreSQL", apiKey: "test-key", boundary: "test-boundary")
        let body = try #require(request.httpBody)
        let string = String(decoding: body, as: UTF8.self)
        #expect(string.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
        #expect(string.contains("name=\"prompt\"\r\n\r\nAcme Corp, PostgreSQL"))
        #expect(string.contains("name=\"file\"; filename=\"audio.wav\""))
        #expect(string.contains("name=\"language\"\r\n\r\nen"))
        #expect(string.contains("name=\"response_format\"\r\n\r\njson"))
        #expect(body.range(of: wav) != nil)
        var expected = Data((
            "--test-boundary\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n" +
            "--test-boundary\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n" +
            "--test-boundary\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n" +
            "--test-boundary\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nAcme Corp, PostgreSQL\r\n" +
            "--test-boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        ).utf8)
        expected.append(wav)
        expected.append(contentsOf: "\r\n--test-boundary--\r\n".utf8)
        #expect(body == expected)
        #expect(request.httpMethod == "POST")
        #expect(request.url == URL(string: "https://api.groq.com/openai/v1/audio/transcriptions"))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary")
    }
    @Test func authorizationHeader() {
        let request = client().makeRequest(wav: Data(), prompt: "", apiKey: "test-key", boundary: "b")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }
    @Test func trimsSuccessfulTranscriptAndUsesRandomBoundary() async throws {
        let transport = FakeTransport(body: #"{"text":" hello world \n"}"#)
        #expect(try await client(transport).transcribe(wav: Data([1, 2]), prompt: "Acme Corp") == "hello world")
        let request = try #require(transport.lastRequest)
        let header = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(header.hasPrefix("multipart/form-data; boundary=dictate-"))
        let boundary = String(header.dropFirst("multipart/form-data; boundary=".count))
        #expect(UUID(uuidString: String(boundary.dropFirst("dictate-".count))) != nil)
        let body = try #require(request.httpBody)
        #expect(body.suffix(Data("--\(boundary)--\r\n".utf8).count) == Data("--\(boundary)--\r\n".utf8))
    }
    @Test func unauthorizedMapsToAuth() async {
        await #expect(throws: TranscriptionError.auth) {
            try await client(FakeTransport(status: 401)).transcribe(wav: Data(), prompt: "")
        }
    }
    @Test func unavailableMapsToServer() async {
        await #expect(throws: TranscriptionError.server(503)) {
            try await client(FakeTransport(status: 503)).transcribe(wav: Data(), prompt: "")
        }
    }
    @Test func rateLimitMapsToClient() async {
        await #expect(throws: TranscriptionError.client(429)) {
            try await client(FakeTransport(status: 429)).transcribe(wav: Data(), prompt: "")
        }
    }
    @Test func timeoutMapsToNetwork() async {
        await #expect(throws: TranscriptionError.network("timedOut")) {
            try await client(FakeTransport(error: URLError(.timedOut))).transcribe(wav: Data(), prompt: "")
        }
        #expect(TranscriptionError.network("timedOut").logReason == "network_timedOut")
        #expect(TranscriptionError.network("timedOut").logReason.hasPrefix("network_"))
    }
    @Test func throwingKeyProviderMapsToMissingKey() async {
        let transport = FakeTransport()
        let client = TranscriptionClient(transport: transport, apiKey: { throw FakeFailure.unavailable })
        await #expect(throws: TranscriptionError.missingKey) {
            try await client.transcribe(wav: Data(), prompt: "")
        }
        #expect(transport.lastRequest == nil)
    }
    @Test func junkBodyMapsToDecode() async {
        await #expect(throws: TranscriptionError.decode) {
            try await client(FakeTransport(body: "junk")).transcribe(wav: Data(), prompt: "")
        }
    }
    @Test func emptyPromptOmitsEntirePart() throws {
        let request = client().makeRequest(wav: Data(), prompt: "", apiKey: "test-key", boundary: "b")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(!body.contains("name=\"prompt\""))
        #expect(body.contains("name=\"file\"; filename=\"audio.wav\""))
        #expect(body.hasSuffix("--b--\r\n"))
    }
    @Test func emptyKeyDoesNotSend() async {
        let transport = FakeTransport()
        let client = TranscriptionClient(transport: transport, apiKey: { " \n\t" })
        await #expect(throws: TranscriptionError.missingKey) {
            try await client.transcribe(wav: Data(), prompt: "")
        }
        #expect(transport.lastRequest == nil)
    }
    @Test func forbiddenMapsToAuth() async {
        await #expect(throws: TranscriptionError.auth) {
            try await client(FakeTransport(status: 403)).transcribe(wav: Data(), prompt: "")
        }
    }
    @Test func otherURLAndTransportErrorsMapToNetwork() async {
        await #expect(throws: TranscriptionError.network("-1009")) {
            try await client(FakeTransport(error: URLError(.notConnectedToInternet))).transcribe(wav: Data(), prompt: "")
        }
        await #expect(throws: TranscriptionError.network("transport")) {
            try await client(FakeTransport(error: FakeFailure.unavailable)).transcribe(wav: Data(), prompt: "")
        }
    }
    @Test func typedTransportErrorIsPreserved() async {
        await #expect(throws: TranscriptionError.auth) {
            try await client(FakeTransport(error: TranscriptionError.auth)).transcribe(wav: Data(), prompt: "")
        }
    }
    @Test func invalidTextShapesFailDecode() async {
        for body in [#"{"text":42}"#, #"{"text":null}"#, #"{"other":"hello"}"#, #"["hello"]"#] {
            await #expect(throws: TranscriptionError.decode) {
                try await client(FakeTransport(body: body)).transcribe(wav: Data(), prompt: "")
            }
        }
    }
    @Test func successRangeAndEmptyText() async throws {
        #expect(try await client(FakeTransport(status: 201, body: #"{"text":" \n"}"#)).transcribe(wav: Data(), prompt: "") == "")
        await #expect(throws: TranscriptionError.decode) {
            try await client(FakeTransport(status: 204, body: "")).transcribe(wav: Data(), prompt: "")
        }
    }
    @Test func logReasons() {
        #expect(TranscriptionError.missingKey.logReason == "missing_key")
        #expect(TranscriptionError.auth.logReason == "auth")
        #expect(TranscriptionError.server(503).logReason == "server_503")
        #expect(TranscriptionError.client(429).logReason == "client_429")
        #expect(TranscriptionError.decode.logReason == "decode")
        #expect(TranscriptionError.network("bad response").logReason == "network_bad_response")
    }
}
