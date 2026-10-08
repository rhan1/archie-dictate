import Foundation

/// A text-frame WebSocket, injectable so the Realtime session tests headless.
public protocol WebSocketTransport: AnyObject, Sendable {
    func connect(url: URL, headers: [String: String]) async throws
    func send(text: String) async throws
    func receive() async throws -> String
    func close()
}

public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func connect(url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.webSocketTask(with: request)
        lock.withLock { self.task = task }
        task.resume()
    }

    public func send(text: String) async throws {
        guard let task = lock.withLock({ task }) else { throw URLError(.notConnectedToInternet) }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task = lock.withLock({ task }) else { throw URLError(.notConnectedToInternet) }
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func close() {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel(with: .normalClosure, reason: nil)
    }
}

public enum RealtimeError: Error, Equatable, Sendable {
    case missingKey
    case connect(String)
    case server(String)
    case timeout
    case closed

    /// Single token for the log line.
    public var logReason: String {
        switch self {
        case .missingKey: return "missing_key"
        case .connect: return "connect"
        case .server: return "server"
        case .timeout: return "timeout"
        case .closed: return "closed"
        }
    }
}

/// v1.1 A1: OpenAI Realtime transcription session. Audio streams WHILE the user
/// speaks. `turn_detection` is null: the app, not server VAD, decides where
/// segments end (at natural pauses, see `PauseSegmenter`) and when the
/// dictation ends, so after the finish tap only the last segment is left.
public final class RealtimeTranscriber: @unchecked Sendable {
    public static let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    public static let sampleRate = 24_000
    public static let model = "gpt-4o-transcribe"
    public static let commitFrame = #"{"type":"input_audio_buffer.commit"}"#

    private let transport: WebSocketTransport
    private let apiKey: @Sendable () throws -> String
    private let prompt: String

    /// Every outbound frame goes through ONE ordered stream, so appends queued
    /// before the socket is open, and every commit, keep their order.
    private let outbound: AsyncStream<String>
    private let outboundContinuation: AsyncStream<String>.Continuation

    private let lock = NSLock()
    private var connected = false
    private var failure: RealtimeError?
    private var finalText: String?
    private var waiter: CheckedContinuation<String, Error>?

    // Every commit becomes one item; the final text is the items' transcripts
    // in commit order.
    private var segmenter: PauseSegmenter
    private var commitsSent = 0
    private var committedItems: [String] = []
    private var transcripts: [String: String] = [:]
    private var finishing = false

    /// `segmentAtPauses` commits at natural pauses so earlier speech is
    /// transcribed while the user is still talking (measured: one commit at
    /// the end left ~2.1 s of transcription after the finish tap).
    public init(transport: WebSocketTransport, prompt: String, segmentAtPauses: Bool = true,
                apiKey: @escaping @Sendable () throws -> String) {
        self.transport = transport
        self.prompt = prompt
        self.apiKey = apiKey
        segmenter = PauseSegmenter(enabled: segmentAtPauses)
        (outbound, outboundContinuation) = AsyncStream.makeStream(of: String.self)
    }

    /// The `session.update` frame, as a pure value so tests can pin its shape.
    public static func sessionUpdate(prompt: String) -> String {
        var transcription: [String: Any] = ["model": model, "language": "en"]
        if !prompt.isEmpty { transcription["prompt"] = prompt }
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ] as [String: Any],
                ],
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Little-endian pcm16, base64, in one `input_audio_buffer.append` frame.
    public static func appendFrame(_ samples: [Int16]) -> String {
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            let raw = UInt16(bitPattern: sample)
            bytes.append(UInt8(raw & 0xFF))
            bytes.append(UInt8(raw >> 8))
        }
        return #"{"type":"input_audio_buffer.append","audio":""# + bytes.base64EncodedString() + #""}"#
    }

    static func eventType(_ frame: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])?["type"] as? String
    }

    public var isConnected: Bool { lock.withLock { connected } }
    static let traceEvents = ProcessInfo.processInfo.environment["DICTATE_TRACE_RT"] == "1"
    public var hasFailed: Bool { lock.withLock { failure != nil } }
    /// Segments committed so far (for the log and the bench).
    public var segmentCount: Int { lock.withLock { committedItems.count } }

    /// Connects and configures the session; queued frames drain afterwards.
    /// Throws `.timeout` if the socket is not open within `timeout` seconds.
    public func open(timeout: TimeInterval = 1.5) async throws {
        let key: String
        do { key = try apiKey() } catch { throw failed(.missingKey) }
        guard !key.isEmpty else { throw failed(.missingKey) }
        // A plain timer, not a task group: a child parked in a continuation
        // would keep the group (and the caller) waiting past the deadline.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.isConnected else { return }
            self.fail(.timeout)
            self.transport.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        do {
            try await transport.connect(url: Self.url, headers: ["Authorization": "Bearer \(key)"])
            // The server never answers pings; its first frame, `session.created`,
            // is the proof the socket is open and authorised.
            let first = try await transport.receive()
            guard Self.eventType(first) == "session.created" else {
                throw RealtimeError.connect(Self.eventType(first) ?? "unexpected first frame")
            }
        } catch {
            watchdog.cancel()
            let reason = (error as? RealtimeError) ?? .connect(String(describing: error))
            throw failed(lock.withLock { failure } ?? reason)
        }
        watchdog.cancel()
        if let failure = lock.withLock({ failure }) { throw failure }
        lock.withLock { connected = true }
        Task { await self.receiveLoop() }
        do {
            try await transport.send(text: Self.sessionUpdate(prompt: prompt))
        } catch {
            throw failed(.connect("session.update: \(error)"))
        }
        Task { await self.sendLoop() }
    }

    /// Thread-safe; callable from the audio thread before or after `open()`.
    public func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        let commitNow = segmenter.shouldCommit(after: samples)
        if commitNow { commitsSent += 1 }
        // Yield under the lock so frames keep the order decided here.
        outboundContinuation.yield(Self.appendFrame(samples))
        if commitNow { outboundContinuation.yield(Self.commitFrame) }
        lock.unlock()
    }

    /// Commits whatever is left and waits until every segment is transcribed.
    public func finish(timeout: TimeInterval = 5) async throws -> String {
        beginFinishing()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail(.timeout)
        }
        return try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<String, Error>) in
            lock.lock()
            if let text = finalText {
                lock.unlock()
                waiter.resume(returning: text)
            } else if let failure {
                lock.unlock()
                waiter.resume(throwing: failure)
            } else {
                self.waiter = waiter
                lock.unlock()
                checkComplete()
            }
        }
    }

    private func beginFinishing() {
        lock.withLock {
            finishing = true
            if segmenter.hasUncommittedSpeech || commitsSent == 0 {
                commitsSent += 1
                outboundContinuation.yield(Self.commitFrame)
                segmenter.markCommitted()
            }
        }
    }

    public func close() {
        outboundContinuation.finish()
        transport.close()
        fail(.closed)
    }

    // MARK: - Loops

    private func sendLoop() async {
        for await frame in outbound {
            do { try await transport.send(text: frame) } catch {
                fail(.server("send_failed"))
                return
            }
        }
    }

    private func receiveLoop() async {
        while true {
            let text: String
            do { text = try await transport.receive() } catch {
                fail(.closed)
                return
            }
            handle(text)
        }
    }

    /// Feeds one server frame (public so tests can drive it directly).
    public func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        if Self.traceEvents, !type.hasSuffix(".delta") {
            FileHandle.standardError.write(Data("rt \(DispatchTime.now().uptimeNanoseconds / 1_000_000) \(type) \((json["error"] as? [String: Any])?["message"] ?? "")\n".utf8))
        }
        switch type {
        case "input_audio_buffer.committed":
            if let item = json["item_id"] as? String { lock.withLock { committedItems.append(item) } }
            checkComplete()
        case "conversation.item.input_audio_transcription.completed":
            if let item = json["item_id"] as? String {
                let transcript = ((json["transcript"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                lock.withLock { transcripts[item] = transcript }
            }
            checkComplete()
        case "conversation.item.input_audio_transcription.failed":
            fail(.server("transcription_failed"))
        case "error":
            let error = json["error"] as? [String: Any]
            if (error?["code"] as? String) == "input_audio_buffer_commit_empty" {
                // A commit that found nothing to commit produces no item.
                lock.withLock { commitsSent = max(0, commitsSent - 1) }
                checkComplete()
            } else {
                fail(.server((error?["code"] as? String) ?? "error"))
            }
        default:
            break
        }
    }

    /// Delivers once finishing, every commit is acknowledged, and every
    /// acknowledged item has its transcript.
    private func checkComplete() {
        lock.lock()
        guard finishing, finalText == nil, committedItems.count >= commitsSent,
              committedItems.allSatisfy({ transcripts[$0] != nil }) else {
            lock.unlock()
            return
        }
        let text = committedItems.compactMap { transcripts[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
        lock.unlock()
        deliver(text)
    }

    private func deliver(_ text: String) {
        lock.lock()
        guard finalText == nil else { lock.unlock(); return }
        finalText = text
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: text)
    }

    private func fail(_ error: RealtimeError) {
        lock.lock()
        guard finalText == nil else { lock.unlock(); return }
        if failure == nil { failure = error }
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    private func failed(_ error: RealtimeError) -> RealtimeError {
        fail(error)
        return error
    }
}
