import Foundation

/// Thread-safe streaming capture; each cut starts an independent upload.
/// WAV is encoded in memory using the existing Core encoder. No file APIs.
public final class GroqChunkedTranscriber: @unchecked Sendable {
    public static let fillerLeadIn = "Um, so, uh, like, Tuesday, no, Wednesday."

    public struct RateLimits: Sendable, Equatable {
        public static let names = ["x-ratelimit-limit-requests", "x-ratelimit-remaining-requests",
                                   "x-ratelimit-limit-tokens", "x-ratelimit-remaining-tokens", "retry-after"]
        public let headers: [String: String]
        public init(response: HTTPURLResponse) {
            headers = Dictionary(uniqueKeysWithValues: Self.names.compactMap { name in
                response.value(forHTTPHeaderField: name).map { (name, $0) }
            })
        }
        // Groq's request headers describe requests/day; its token headers
        // describe tokens/minute. They do not report remaining requests/minute.
        public var rpmRemaining: String { "-" }
        public var rpdRemaining: String { count("x-ratelimit-remaining-requests") }
        public func count(_ name: String) -> String {
            guard let value = headers[name], !value.isEmpty,
                  value.allSatisfy({ "0123456789.-".contains($0) }) else { return "-" }
            return value
        }
    }
    public struct Call: Sendable, Equatable {
        public let index: Int
        public let attempt: Int
        public let milliseconds: Int
        public let status: Int?
        public let hedgeFired: Bool
        /// 1 = primary, 2 = duplicate; nil when neither succeeded.
        public let winningRequest: Int?
    }
    public struct Result: Sendable {
        public let text: String
        public let chunks: Int
        public let failedCount: Int
        public let lastChunkMs: Int
        public let sttMs: Int
        public let calls: [Call]
        public let hedges: Int
        public let hedgeWins: Int
        public let rateLimits: RateLimits?
    }

    private let lock = NSLock()
    private let client: TranscriptionClient
    private let vocabulary: String
    private let hedgeAfterMs: Int
    private let finalSplitSeconds: Double?
    private let includesFillerLeadIn: Bool
    private let onChunkText: (@Sendable (Int, String) -> Void)?
    private var chunker: PauseChunker
    private var tasks: [Task<Void, Never>] = []
    private var texts: [Int: String] = [:]
    private var failures: Set<Int> = []
    private var calls: [Call] = []
    private var limits: RateLimits?
    private var lastResponse: UInt64?
    private var finishAt: UInt64?
    private var closed = false

    public init(transport: HTTPTransport, apiKey: @escaping @Sendable () throws -> String, prompt: String,
                fillerLeadIn: Bool = true, firstMinimumSeconds: Double = 3.0, firstMaximumSeconds: Double = 4.0,
                hedgeAfterMs: Int = 700, finalSplitSeconds: Double? = 2.0,
                onChunkText: (@Sendable (Int, String) -> Void)? = nil) {
        var client = TranscriptionClient(transport: transport, apiKey: apiKey)
        client.endpointURL = TranscriptionClient.groqEndpoint
        client.modelName = "whisper-large-v3-turbo"
        self.client = client
        self.hedgeAfterMs = max(0, hedgeAfterMs)
        self.finalSplitSeconds = finalSplitSeconds
        // Cap only vocabulary: preserve the lead-in and the bounded previous tail.
        vocabulary = String(prompt.prefix(Vocabulary.maxPromptLength))
        includesFillerLeadIn = fillerLeadIn
        self.onChunkText = onChunkText
        chunker = PauseChunker(firstMinimumSeconds: firstMinimumSeconds, firstMaximumSeconds: firstMaximumSeconds)
    }

    public func append(_ pcm: [Int16]) {
        lock.withLock {
            guard !closed else { return }
            for chunk in chunker.append(pcm) { enqueue(chunk) }
        }
    }

    /// Also accepts already-cut chunks for callers using PauseChunker directly.
    @discardableResult
    public func submit(_ chunk: PauseChunker.Chunk) -> Task<Void, Never>? {
        lock.withLock {
            guard !closed else { return nil }
            return enqueue(chunk)
        }
    }

    // Called with the lock held. Detached tasks never inherit the UI executor.
    @discardableResult
    private func enqueue(_ chunk: PauseChunker.Chunk) -> Task<Void, Never> {
        let task = Task.detached { [self] in await upload(chunk) }
        tasks.append(task)
        return task
    }

    /// Windowed-sinc low-pass resampling: removes frequencies above 8 kHz
    /// before decimating 24 kHz to 16 kHz (32 taps, Hann window).
    public static func resampleTo16k(_ pcm: [Int16]) -> [Int16] {
        guard !pcm.isEmpty else { return [] }
        return (0..<(pcm.count * 2 / 3)).map { output in
            let position = Double(output) * 1.5
            let center = Int(position)
            var sum = 0.0, weight = 0.0
            for input in (center - 15)...(center + 16) {
                let distance = Double(input) - position
                guard abs(distance) < 16 else { continue }
                let x = distance * (2.0 / 3.0)
                let sinc = abs(x) < 1e-10 ? 1 : sin(.pi * x) / (.pi * x)
                let coefficient = (2.0 / 3.0) * sinc * (0.5 + 0.5 * cos(.pi * distance / 16))
                sum += Double(pcm[min(pcm.count - 1, max(0, input))]) * coefficient
                weight += coefficient
            }
            return Int16(clamping: Int((sum / weight).rounded()))
        }
    }

    private struct Response: Sendable {
        let text: String?
        let http: HTTPURLResponse?
    }
    private enum RequestEvent: Sendable {
        case response(Int, Response)
        case hedge
    }
    private struct AttemptResult {
        let text: String?
        let status: Int?
        let hedgeFired: Bool
        let winningRequest: Int?
    }

    private func send(_ request: URLRequest) async -> Response {
        do {
            let (data, response) = try await client.transport.send(request)
            guard (200...299).contains(response.statusCode) else { return Response(text: nil, http: response) }
            struct Transcript: Decodable { let text: String }
            let text = (try? JSONDecoder().decode(Transcript.self, from: data))?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Response(text: text, http: response)
        } catch { return Response(text: nil, http: nil) }
    }

    /// Unstructured workers let the winner return even if a transport ignores
    /// cancellation. Only this consumer publishes responses; late losers are ignored.
    private func requestAttempt(_ request: URLRequest, hedged: Bool) async -> AttemptResult {
        let (events, continuation) = AsyncStream<RequestEvent>.makeStream()
        let primary = Task.detached { [self] in
            continuation.yield(.response(1, await send(request)))
        }
        let timer: Task<Void, Never>? = hedged ? Task.detached { [hedgeAfterMs] in
            do {
                try await Task.sleep(for: .milliseconds(hedgeAfterMs))
                if !Task.isCancelled { continuation.yield(.hedge) }
            } catch {}
        } : nil
        var duplicate: Task<Void, Never>?
        defer {
            continuation.finish()
            primary.cancel()
            duplicate?.cancel()
            timer?.cancel()
        }
        var fired = false
        var completed = 0
        var status: Int?
        for await event in events {
            if Task.isCancelled { break }
            switch event {
            case .hedge:
                guard !fired else { continue }
                fired = true
                duplicate = Task.detached { [self] in
                    continuation.yield(.response(2, await send(request)))
                }
            case .response(let number, let response):
                completed += 1
                status = response.http?.statusCode
                if let http = response.http {
                    lock.withLock {
                        limits = RateLimits(response: http)
                        lastResponse = DispatchTime.now().uptimeNanoseconds
                    }
                }
                if let text = response.text {
                    return AttemptResult(text: text, status: status, hedgeFired: fired, winningRequest: number)
                }
                // Failure before the timer goes straight to today's attempt 2.
                // After a hedge, wait for the other response to have a chance.
                if !fired || completed == 2 {
                    return AttemptResult(text: nil, status: status, hedgeFired: fired, winningRequest: nil)
                }
            }
        }
        return AttemptResult(text: nil, status: status, hedgeFired: fired, winningRequest: nil)
    }

    private func upload(_ chunk: PauseChunker.Chunk) async {
        let wav = WAVEncoder.encode(samples: Self.resampleTo16k(chunk.samples), sampleRate: 16_000)
        for attempt in 1...2 {
            if Task.isCancelled { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let outcome: AttemptResult
            do {
                let key: String
                do { key = try client.apiKey().trimmingCharacters(in: .whitespacesAndNewlines) }
                catch { throw TranscriptionError.missingKey }
                guard !key.isEmpty else { throw TranscriptionError.missingKey }
                let prompt = lock.withLock {
                    let tail = texts[chunk.index - 1].map { String($0.suffix(200)) } ?? ""
                    return (includesFillerLeadIn ? Self.fillerLeadIn + " " : "") + vocabulary +
                           (tail.isEmpty ? "" : " " + tail)
                }
                let request = client.makeRequest(wav: wav, prompt: prompt, apiKey: key,
                                                 boundary: "dictate-\(UUID().uuidString)", includeEmptyPrompt: true)
                outcome = await requestAttempt(request, hedged: attempt == 1)
            } catch {
                outcome = AttemptResult(text: nil, status: nil, hedgeFired: false, winningRequest: nil)
            }
            if Task.isCancelled { return }
            lock.withLock {
                calls.append(Call(index: chunk.index, attempt: attempt, milliseconds: Self.ms(from: start),
                                  status: outcome.status, hedgeFired: outcome.hedgeFired,
                                  winningRequest: outcome.winningRequest))
                if let text = outcome.text { texts[chunk.index] = text }
                else if attempt == 2 { failures.insert(chunk.index) }
            }
            if let text = outcome.text {
                onChunkText?(chunk.index, text)
                return
            }
        }
    }

    public func finish(at finish: DispatchTime = .now()) async -> Result {
        let pending = lock.withLock {
            if finishAt == nil { finishAt = finish.uptimeNanoseconds }
            if !closed {
                closed = true
                let final = chunker.finish(splitOver: finalSplitSeconds)
                // Splitting must preserve even a tiny opening piece. Keep the
                // existing 300 ms floor only for an unsplit final partial.
                for chunk in final where final.count > 1 || chunk.samples.count >= 7_200 { enqueue(chunk) }
            }
            return tasks
        }
        for task in pending { await task.value }
        return lock.withLock {
            let start = finishAt!
            let lastMs = lastResponse.map { $0 > start ? Int(($0 - start) / 1_000_000) : 0 } ?? 0
            return Result(text: texts.keys.sorted().compactMap { texts[$0] }.filter { !$0.isEmpty }.joined(separator: " "),
                          chunks: tasks.count, failedCount: failures.count, lastChunkMs: lastMs,
                          sttMs: Self.ms(from: start), calls: calls,
                          hedges: calls.filter { $0.hedgeFired }.count,
                          hedgeWins: calls.filter { $0.winningRequest == 2 }.count, rateLimits: limits)
        }
    }

    public func cancel() {
        lock.withLock {
            closed = true
            for task in tasks { task.cancel() }
            _ = chunker.finish()
        }
    }

    private static func ms(from start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
