import Foundation

/// One WebSocket per recording. Only final Results enter the existing chunk pipeline.
public final class DeepgramStreamingTranscriber: @unchecked Sendable {
    public static let listenURL = "wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=24000&channels=1&interim_results=true&smart_format=true&punctuate=true"
    public static let closeStream = "{\"type\":\"CloseStream\"}"
    private let lock = NSLock()
    private let transport: any WebSocketTransport
    private let apiKey: @Sendable () throws -> String
    private let keytermsURL: URL?
    private let clock: any DictateClock
    private let receiveTimeout: Duration
    private let onChunkText: (@Sendable (Int, String) -> Void)?
    private let stream: AsyncStream<[Int16]>
    private let input: AsyncStream<[Int16]>.Continuation
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var completion: Task<GroqChunkedTranscriber.Result, Never>?
    private var connection: (any WebSocketConnection)?
    private var stopping = false
    private var cancelled = false
    private var failure: String?
    private var finals: [String] = []

    public init(transport: any WebSocketTransport = URLSessionWebSocketTransport(),
                apiKey: @escaping @Sendable () throws -> String,
                keytermsURL: URL? = nil, clock: any DictateClock = SystemClock(),
                receiveTimeout: Duration = .seconds(15),
                onChunkText: (@Sendable (Int, String) -> Void)? = nil) {
        self.transport = transport
        self.apiKey = apiKey
        self.keytermsURL = keytermsURL
        self.clock = clock
        self.receiveTimeout = receiveTimeout
        self.onChunkText = onChunkText
        let pair = AsyncStream<[Int16]>.makeStream()
        stream = pair.stream
        input = pair.continuation
    }

    /// The cap applies to the first fifty physical lines; blank lines add no keyterm.
    public static func makeRequest(apiKey: String, keytermsURL: URL?) -> URLRequest {
        let lines = keytermsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let terms = lines.components(separatedBy: "\n").prefix(50).compactMap { line -> String? in
            let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return term.isEmpty ? nil : term.addingPercentEncoding(withAllowedCharacters: allowed)
        }
        let url = listenURL + terms.map { "&keyterm=" + $0 }.joined()
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Token " + apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    public var fallbackReason: String? { lock.withLock { failure } }

    public func append(_ pcm: [Int16]) {
        lock.withLock {
            guard !stopping, !cancelled else { return }
            input.yield(pcm)
            startLocked()
        }
    }

    private func startLocked() {
        guard sender == nil else { return }
        sender = Task { [self] in await sendAudio() }
    }

    private func fail(_ reason: String) {
        let socket = lock.withLock { () -> (any WebSocketConnection)? in
            if failure == nil, !cancelled { failure = reason }
            return connection
        }
        input.finish()
        socket?.close()
    }

    private func sendAudio() async {
        let key: String
        do {
            key = try apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { fail("missing_key"); return }
        } catch { fail("missing_key"); return }
        let socket: any WebSocketConnection
        do { socket = try await transport.connect(Self.makeRequest(apiKey: key, keytermsURL: keytermsURL)) }
        catch { fail("connect"); return }
        let shouldClose = lock.withLock { () -> Bool in
            connection = socket
            return cancelled
        }
        guard !shouldClose else { socket.close(); return }
        let receiving = Task { [self] in await receiveResults(socket) }
        lock.withLock { receiver = receiving }
        do {
            for await pcm in stream {
                if Task.isCancelled || lock.withLock({ failure != nil || cancelled }) { break }
                var data = Data(capacity: pcm.count * 2)
                for sample in pcm {
                    let bits = UInt16(bitPattern: sample)
                    data.append(UInt8(truncatingIfNeeded: bits))
                    data.append(UInt8(truncatingIfNeeded: bits >> 8))
                }
                try await socket.send(data)
            }
        } catch { fail("socket") }
    }

    private enum ReceiveError: Error { case timeout }
    private func receiveResults(_ socket: any WebSocketConnection) async {
        do {
            while !Task.isCancelled {
                let message = try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask { try await socket.receive() }
                    group.addTask { [self] in
                        try await clock.sleep(for: receiveTimeout)
                        if !lock.withLock({ stopping || cancelled }) { fail("timeout") }
                        socket.close() // also unblock transports whose receive is not cancellation-aware
                        throw ReceiveError.timeout
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                guard let message else {
                    if !lock.withLock({ stopping || cancelled }) { fail("socket") }
                    return
                }
                consume(message)
            }
        } catch {
            if !lock.withLock({ stopping || cancelled }) {
                fail(error is ReceiveError ? "timeout" : "socket")
            }
        }
    }

    private func consume(_ message: String) {
        struct Results: Decodable {
            struct Channel: Decodable {
                struct Alternative: Decodable { let transcript: String }
                let alternatives: [Alternative]
            }
            let type: String
            let channel: Channel?
            let is_final: Bool?
            let speech_final: Bool?
        }
        guard let frame = try? JSONDecoder().decode(Results.self, from: Data(message.utf8)),
              frame.type == "Results", frame.is_final == true,
              let text = frame.channel?.alternatives.first?.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        let index = lock.withLock { () -> Int? in
            guard failure == nil, !cancelled else { return nil }
            finals.append(text)
            return finals.count - 1
        }
        if let index { onChunkText?(index, text) }
    }

    public func finish(at finish: DispatchTime = .now()) async -> GroqChunkedTranscriber.Result {
        let task = lock.withLock { () -> Task<GroqChunkedTranscriber.Result, Never> in
            if let completion { return completion }
            stopping = true
            input.finish()
            startLocked()
            let task = Task { [self] in await complete(at: finish) }
            completion = task
            return task
        }
        return await task.value
    }

    private func complete(at finish: DispatchTime) async -> GroqChunkedTranscriber.Result {
        await lock.withLock { sender }?.value
        let (socket, receiving) = lock.withLock { (connection, receiver) }
        if let socket, lock.withLock({ failure == nil && !cancelled }) {
            do { try await socket.send(Self.closeStream) }
            catch { fail("socket") }
            // A fixed deadline, never extended by interim or final messages.
            let deadline = clock.now().advanced(by: .milliseconds(1500))
            let timeout = Task { [clock] in
                do { try await clock.sleep(until: deadline); socket.close() }
                catch { }
            }
            await receiving?.value
            timeout.cancel()
        }
        socket?.close()
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - finish.uptimeNanoseconds) / 1_000_000)
        return lock.withLock {
            GroqChunkedTranscriber.Result(text: finals.joined(separator: " "), chunks: finals.count,
                rejoins: 0, failedCount: failure == nil && !cancelled ? 0 : 1,
                lastChunkMs: elapsed, sttMs: elapsed, calls: [], hedges: 0, hedgeWins: 0, rateLimits: nil)
        }
    }

    public func cancel() {
        let tasks = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?, (any WebSocketConnection)?) in
            cancelled = true
            stopping = true
            return (sender, receiver, connection)
        }
        input.finish()
        tasks.0?.cancel()
        tasks.1?.cancel()
        tasks.2?.close()
    }
}
