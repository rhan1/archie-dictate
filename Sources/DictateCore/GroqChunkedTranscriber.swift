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
    }
    public struct Result: Sendable {
        public let text: String
        public let chunks: Int
        public let failedCount: Int
        public let lastChunkMs: Int
        public let sttMs: Int
        public let calls: [Call]
        public let rateLimits: RateLimits?
    }

    private let lock = NSLock()
    private let client: TranscriptionClient
    private let vocabulary: String
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
                onChunkText: (@Sendable (Int, String) -> Void)? = nil) {
        var client = TranscriptionClient(transport: transport, apiKey: apiKey)
        client.endpointURL = TranscriptionClient.groqEndpoint
        client.modelName = "whisper-large-v3-turbo"
        self.client = client
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

    private func upload(_ chunk: PauseChunker.Chunk) async {
        let wav = WAVEncoder.encode(samples: Self.resampleTo16k(chunk.samples), sampleRate: 16_000)
        for attempt in 1...2 {
            if Task.isCancelled { return }
            let start = DispatchTime.now().uptimeNanoseconds
            var status: Int?
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
                let (data, response) = try await client.transport.send(request)
                status = response.statusCode
                lock.withLock {
                    limits = RateLimits(response: response)
                    lastResponse = DispatchTime.now().uptimeNanoseconds
                }
                guard (200...299).contains(response.statusCode) else {
                    throw TranscriptionError.client(response.statusCode)
                }
                struct Transcript: Decodable { let text: String }
                guard let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else {
                    throw TranscriptionError.decode
                }
                lock.withLock {
                    texts[chunk.index] = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    calls.append(Call(index: chunk.index, attempt: attempt,
                                      milliseconds: Self.ms(from: start), status: status))
                }
                onChunkText?(chunk.index, transcript.text.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            } catch {
                lock.withLock {
                    calls.append(Call(index: chunk.index, attempt: attempt,
                                      milliseconds: Self.ms(from: start), status: status))
                    if attempt == 2 { failures.insert(chunk.index) }
                }
            }
        }
    }

    public func finish(at finish: DispatchTime = .now()) async -> Result {
        let pending = lock.withLock {
            if finishAt == nil { finishAt = finish.uptimeNanoseconds }
            if !closed {
                closed = true
                for chunk in chunker.finish() where chunk.samples.count >= 7_200 { enqueue(chunk) }
            }
            return tasks
        }
        for task in pending { await task.value }
        return lock.withLock {
            let start = finishAt!
            let lastMs = lastResponse.map { $0 > start ? Int(($0 - start) / 1_000_000) : 0 } ?? 0
            return Result(text: texts.keys.sorted().compactMap { texts[$0] }.filter { !$0.isEmpty }.joined(separator: " "),
                          chunks: tasks.count, failedCount: failures.count, lastChunkMs: lastMs,
                          sttMs: Self.ms(from: start), calls: calls, rateLimits: limits)
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
