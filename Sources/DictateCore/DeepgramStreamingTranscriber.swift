import Foundation

/// v1.19 (ST1): Deepgram nova-3 live transcription over Dictate's own WebSocket seam.
///
/// One socket per recording. Audio is raw little-endian Int16, 24 kHz mono (`linear16`, no WAV header).
/// Only final, non-duplicate `Results` reach `onFinalSegment(index, text)`, with contiguous zero-based
/// indexes. `finish` drains every queued send, sends `CloseStream`, then awaits terminal completion
/// (`Metadata`, or the server closing the socket) for at most 1.5 s on the injected clock.
/// Anything else — missing key, connect/socket error, a silent socket, no terminal in time, cancel —
/// is an INCOMPLETE result: callbacks stop at once and the host recovers from the whole recording.
/// This type never transcribes anything itself and never logs words or the key.
public final class DeepgramStreamingTranscriber: StreamingSTTSession, @unchecked Sendable {
    public static let endpoint = "wss://api.deepgram.com/v1/listen"
    public static let baseQuery: [(name: String, value: String)] = [
        ("model", "nova-3"), ("encoding", "linear16"), ("sample_rate", "24000"), ("channels", "1"),
        ("interim_results", "true"), ("smart_format", "true"), ("punctuate", "true"),
    ]
    public static let maxKeyterms = 50
    /// Terminal completion is accepted up to and including this long after CloseStream.
    public static let terminalWait: Duration = .milliseconds(1500)
    public static let closeStream = "{\"type\":\"CloseStream\"}"

    private let lock = NSLock()
    /// Serialises final callbacks against fail/cancel: once closed, no callback can start.
    private let gate = NSLock()
    private var callbacksOpen = true
    private let transport: any WebSocketTransport
    private let apiKey: @Sendable () throws -> String
    private let keytermsURL: URL?
    private let clock: any DictateClock
    private let receiveTimeout: Duration
    private let onFinalSegment: (@Sendable (Int, String) -> Void)?
    private let onFailure: (@Sendable (String) -> Void)?
    private let stream: AsyncStream<[Int16]>
    private let input: AsyncStream<[Int16]>.Continuation
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var completion: Task<StreamingSTTResult, Never>?
    private var connection: (any WebSocketConnection)?
    private var stopping = false
    private var closeSentAt: ContinuousClock.Instant?
    private var terminal = false
    private var cancelled = false
    private var failure: String?
    private var finals: [String] = []
    private var lastFinalEnd: Double?
    private var diagnostics = StreamingSTTResult.Diagnostics(provider: "deepgram")

    /// - receiveTimeout: while recording, a socket silent this long is a failure (`timeout`).
    /// - onFailure: called once, on the failing task, when the session becomes incomplete
    ///   (not on `cancel`): the host cancels this session's incremental cleanup there.
    public init(transport: any WebSocketTransport = URLSessionWebSocketTransport(),
                apiKey: @escaping @Sendable () throws -> String,
                keytermsURL: URL? = nil, clock: any DictateClock = SystemClock(),
                receiveTimeout: Duration = .seconds(15),
                onFinalSegment: (@Sendable (Int, String) -> Void)? = nil,
                onFailure: (@Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.apiKey = apiKey
        self.keytermsURL = keytermsURL
        self.clock = clock
        self.receiveTimeout = receiveTimeout
        self.onFinalSegment = onFinalSegment
        self.onFailure = onFailure
        let pair = AsyncStream<[Int16]>.makeStream()
        stream = pair.stream
        input = pair.continuation
    }

    // MARK: - Request

    /// The newest `maxKeyterms` terms of the ST2 learner's store (`KeytermsStore`, cap 200, newest-last);
    /// a missing file is no terms.
    public static func keyterms(from url: URL?) -> [String] {
        guard let url else { return [] }
        return KeytermsStore(url: url).newest(maxKeyterms)
    }

    /// `URLComponents` with every name/value percent-encoded to RFC 3986 unreserved characters,
    /// one repeated `keyterm` item per term.
    public static func makeRequest(apiKey: String, keyterms: [String]) -> URLRequest {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        var components = URLComponents(string: endpoint)!
        let items = baseQuery + keyterms.prefix(maxKeyterms).map { (name: "keyterm", value: $0) }
        components.percentEncodedQueryItems = items.map { URLQueryItem(name: encode($0.name), value: encode($0.value)) }
        var request = URLRequest(url: components.url!)
        request.setValue("Token " + apiKey, forHTTPHeaderField: "Authorization")
        return request
    }

    public static func makeRequest(apiKey: String, keytermsURL: URL?) -> URLRequest {
        makeRequest(apiKey: apiKey, keyterms: keyterms(from: keytermsURL))
    }

    /// Raw little-endian Int16 samples: Deepgram's `linear16` body (no header).
    public static func linear16(_ pcm: [Int16]) -> Data {
        var data = Data(capacity: pcm.count * 2)
        for sample in pcm {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    // MARK: - Session

    public func append(_ pcm: [Int16]) {
        lock.withLock {
            guard !stopping, !cancelled, failure == nil else { return }
            input.yield(pcm)
            startLocked()
        }
    }

    private func startLocked() {
        guard sender == nil else { return }
        sender = Task { [self] in await sendAudio() }
    }

    private func closeCallbacks() { gate.withLock { callbacksOpen = false } }

    /// First failure wins; later ones (and any after terminal completion or cancel) are ignored.
    private func fail(_ reason: String) {
        let (first, socket) = lock.withLock { () -> (Bool, (any WebSocketConnection)?) in
            guard failure == nil, !cancelled, !terminal else { return (false, nil) }
            failure = reason
            diagnostics.failureReason = reason
            return (true, connection)
        }
        guard first else { return }
        closeCallbacks()
        input.finish()
        socket?.close()
        onFailure?(reason)
    }

    private func sendAudio() async {
        let key: String
        do { key = try apiKey().trimmingCharacters(in: .whitespacesAndNewlines) } catch { fail("missing_key"); return }
        guard !key.isEmpty else { fail("missing_key"); return }
        guard !lock.withLock({ cancelled || failure != nil }) else { return }
        let socket: any WebSocketConnection
        do { socket = try await transport.connect(Self.makeRequest(apiKey: key, keytermsURL: keytermsURL)) }
        catch { fail("connect"); return }
        let abandoned = lock.withLock { () -> Bool in
            diagnostics.connects += 1
            connection = socket
            return cancelled || failure != nil
        }
        guard !abandoned else { socket.close(); return }
        let receiving = Task { [self] in await receiveResults(socket) }
        lock.withLock { receiver = receiving }
        do {
            for await pcm in stream {
                if lock.withLock({ failure != nil || cancelled }) { break }
                try await socket.send(Self.linear16(pcm))
            }
        } catch { fail("socket") }
    }

    private enum Event: Sendable { case message(String), closed, watchdog }

    private func receiveResults(_ socket: any WebSocketConnection) async {
        while true {
            let event: Event
            do { event = try await nextEvent(socket) } catch { fail("socket"); return }
            switch event {
            case .message(let text):
                if consume(text) { markTerminal(); return }
            case .closed:
                // A close after CloseStream is the server's terminal; before it, a lost socket.
                if lock.withLock({ closeSentAt != nil }) { markTerminal() } else { fail("socket") }
                return
            case .watchdog:
                return   // `fail("timeout")` already closed the socket
            }
        }
    }

    /// While recording, a receive races the silence watchdog; after stop the terminal deadline governs.
    private func nextEvent(_ socket: any WebSocketConnection) async throws -> Event {
        guard !lock.withLock({ stopping }) else {
            return try await socket.receive().map(Event.message) ?? .closed
        }
        return try await withThrowingTaskGroup(of: Event.self) { group in
            group.addTask { try await socket.receive().map(Event.message) ?? .closed }
            group.addTask { [self] in
                try await clock.sleep(for: receiveTimeout)
                // Failing here closes the socket, which ends the pending receive above.
                if !lock.withLock({ stopping }) { fail("timeout") }
                return .watchdog
            }
            defer { group.cancelAll() }
            while let event = try await group.next() {
                if case .watchdog = event, lock.withLock({ stopping && failure == nil }) { continue }
                return event
            }
            return .closed
        }
    }

    private func markTerminal() {
        lock.withLock {
            guard failure == nil, !cancelled, let closeSentAt else { return }
            terminal = true
            let elapsed = closeSentAt.duration(to: clock.now())
            diagnostics.terminalMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        }
    }

    private struct Frame: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable { let transcript: String }
            let alternatives: [Alternative]
        }
        let type: String
        let channel: Channel?
        let is_final: Bool?
        let start: Double?
        let duration: Double?
    }

    /// True when the frame is the terminal `Metadata` after CloseStream.
    private func consume(_ message: String) -> Bool {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(message.utf8)) else { return false }
        if frame.type == "Metadata" { return lock.withLock { closeSentAt != nil } }
        guard frame.type == "Results" else { return false }
        guard frame.is_final == true else {
            lock.withLock { diagnostics.interimFrames += 1 }
            return false
        }
        let text = frame.channel?.alternatives.first?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        gate.withLock {
            guard callbacksOpen else { return }
            let index = lock.withLock { () -> Int? in
                if let start = frame.start, let duration = frame.duration {
                    // A final that ends no later than an accepted one re-covers audio already final.
                    if let last = lastFinalEnd, start + duration <= last + 0.0005 {
                        diagnostics.duplicateFinals += 1
                        return nil
                    }
                    lastFinalEnd = start + duration
                }
                guard !text.isEmpty else { return nil }
                finals.append(text)
                if closeSentAt != nil { diagnostics.lateFinals += 1 }
                else if !stopping { diagnostics.finalsBeforeStop += 1 }
                return finals.count - 1
            }
            if let index { onFinalSegment?(index, text) }
        }
        return false
    }

    public func finish(at finish: DispatchTime = .now()) async -> StreamingSTTResult {
        let task = lock.withLock { () -> Task<StreamingSTTResult, Never> in
            if let completion { return completion }
            stopping = true
            input.finish()   // the sender drains every queued chunk, then ends
            if !cancelled, failure == nil { startLocked() }
            let task = Task { [self] in await complete() }
            completion = task
            return task
        }
        return await task.value
    }

    private func complete() async -> StreamingSTTResult {
        await lock.withLock { sender }?.value
        let (socket, receiving, live) = lock.withLock { (connection, receiver, failure == nil && !cancelled) }
        if let socket, live {
            let sentAt = clock.now()
            lock.withLock { closeSentAt = sentAt }
            do {
                try await socket.send(Self.closeStream)
                lock.withLock { diagnostics.closeStreams += 1 }
                let timeout = Task { [self] in
                    do { try await clock.sleep(until: sentAt.advanced(by: Self.terminalWait + .milliseconds(1))) }
                    catch { return }
                    fail("terminal_timeout")
                }
                await receiving?.value
                timeout.cancel()
            } catch { fail("socket") }
        }
        socket?.close()
        await receiving?.value
        return lock.withLock {
            StreamingSTTResult(text: finals.joined(separator: " "), finalSegments: finals.count,
                               complete: terminal && failure == nil && !cancelled, diagnostics: diagnostics)
        }
    }

    public func cancel() {
        let (sending, receiving, socket) = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?, (any WebSocketConnection)?) in
            cancelled = true
            stopping = true
            if diagnostics.failureReason == nil { diagnostics.failureReason = "cancelled" }
            return (sender, receiver, connection)
        }
        closeCallbacks()
        input.finish()
        sending?.cancel()
        receiving?.cancel()
        socket?.close()
    }
}
