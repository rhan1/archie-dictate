import Foundation

/// Thread-safe streaming capture; each cut starts an independent upload.
/// WAV is encoded in memory using the existing Core encoder. No file APIs.
public final class GroqChunkedTranscriber: @unchecked Sendable {
    public static let fillerLeadIn = "Um, so, uh, like, Tuesday, no, Wednesday."

    /// A chunk that starts like this is probably the tail of a split "uh, the X".
    /// Keep this small list public so probe runs can tune it in one place.
    public static let rejoinTriggers = ["other ", "it?"]
    /// The previous chunk ending like this is the other half of the R5 "check it? TurnoutWatch this" split.
    static let rejoinSuffixes = ["check it", "check it?"]
    /// Bounded cost: at most this many pair requests per dictation (one per boundary).
    public static let maxRejoins = 2

    /// DICTATE_REJOIN_GUARD=0 turns the guard off; anything else (or unset) leaves it on.
    public static func rejoinGuardEnabled(environment: [String: String]) -> Bool {
        environment["DICTATE_REJOIN_GUARD"] != "0"
    }

    /// v1.11 L1: the v1.10 novelty rule (a long sentence whose words appear in neither the
    /// vocabulary nor the next chunk) deletes valid text — "Hey. Cancel the London booking." lost
    /// its instruction (GPT-6 review §H). Off unless DICTATE_LOW_SPEECH_GUARD=1.
    public static func lowSpeechGuardEnabled(environment: [String: String]) -> Bool {
        environment["DICTATE_LOW_SPEECH_GUARD"] == "1"
    }

    /// DICTATE_EDGE_GUARD=0 turns the v1.11 audio-evidence guard (silent chunks, invented opening and
    /// trailing sentences) off; anything else enables it.
    public static func edgeGuardEnabled(environment: [String: String]) -> Bool {
        environment["DICTATE_EDGE_GUARD"] != "0"
    }

    public static func shouldRejoin(previous: String, current: String,
                                    cutKind: PauseChunker.CutKind, quietRunMs: Int?) -> Bool {
        guard cutKind == .forced || (cutKind == .pause && quietRunMs.map { $0 < 400 } == true) else { return false }
        let before = previous.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let after = String(current.lowercased().drop { $0.isWhitespace || $0.isPunctuation })
        guard !before.isEmpty else { return false }
        // Exact word boundaries avoid triggering on e.g. "doublecheck it". Checked before the
        // sentence-end guard because the fragment itself ends in "?".
        if rejoinSuffixes.contains(where: { before == $0 || before.hasSuffix(" " + $0) }) { return true }
        guard !before.hasSuffix("."), !before.hasSuffix("?"), !before.hasSuffix("!") else { return false }
        return rejoinTriggers.contains { after.hasPrefix($0) }
    }

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
        public let model: String
        public let isFinal: Bool
        public let isRejoin: Bool
        public let milliseconds: Int
        public let status: Int?
        public let hedgeFired: Bool
        /// 1 = primary, 2 = duplicate; nil when neither succeeded.
        public let winningRequest: Int?
    }
    public struct Result: Sendable {
        public let text: String
        public let chunks: Int
        /// Number of experimental rejoin requests, including failed requests.
        public let rejoins: Int
        public let failedCount: Int
        public let lastChunkMs: Int
        public let sttMs: Int
        public let calls: [Call]
        public let hedges: Int
        public let hedgeWins: Int
        public let rateLimits: RateLimits?
        /// Long sentences removed from low-speech, non-final chunks (v1.10 novelty rule; off by default).
        public let droppedLowSpeechSentences: Int
        /// v1.11 L1: sentences over non-speech after the last speech section (not a known artifact).
        public let droppedTailSentences: Int
        /// v1.11 L1: sentences over non-speech before the first speech section (not a known artifact).
        public let droppedOpeningSentences: Int
        /// v1.11 L1: edge sentences over non-speech that were a known artifact ("Thank you.").
        public let droppedArtifacts: Int
        /// v1.11 L1: chunks with no speech window by the dictation's rule (their whole text).
        public let droppedSilentChunks: Int

        public init(text: String, chunks: Int, rejoins: Int, failedCount: Int, lastChunkMs: Int, sttMs: Int,
                    calls: [Call], hedges: Int, hedgeWins: Int, rateLimits: RateLimits?,
                    droppedLowSpeechSentences: Int = 0, droppedTailSentences: Int = 0,
                    droppedOpeningSentences: Int = 0, droppedArtifacts: Int = 0, droppedSilentChunks: Int = 0) {
            self.text = text
            self.chunks = chunks
            self.rejoins = rejoins
            self.failedCount = failedCount
            self.lastChunkMs = lastChunkMs
            self.sttMs = sttMs
            self.calls = calls
            self.hedges = hedges
            self.hedgeWins = hedgeWins
            self.rateLimits = rateLimits
            self.droppedLowSpeechSentences = droppedLowSpeechSentences
            self.droppedTailSentences = droppedTailSentences
            self.droppedOpeningSentences = droppedOpeningSentences
            self.droppedArtifacts = droppedArtifacts
            self.droppedSilentChunks = droppedSilentChunks
        }
    }

    private let lock = NSLock()
    private let client: TranscriptionClient
    private let vocabulary: String
    private let hedgeAfterMs: Int
    private let clock: any DictateClock
    private let finalSplitSeconds: Double?
    private let leadIn: String
    private let finalModel: String?
    private let rejoinGuard: Bool
    private let lowSpeechGuard: Bool
    private var originalChunks: [Int: PauseChunker.Chunk] = [:]
    private var speechRatios: [Int: Double] = [:]
    /// v1.10 L3: chunks the low-speech guard already judged, and what it dropped from each.
    private var guarded: Set<Int> = []
    private var droppedByIndex: [Int: Int] = [:]
    /// v1.11 L1: each chunk's 50 ms RMS windows (a rejoined pair's on the earlier index), the
    /// indices rejoined into their predecessor, chunks judged for silence, and what was dropped.
    private let edgeGuard: Bool
    private var windowsByIndex: [Int: [Float]] = [:]
    private var rejoined: Set<Int> = []
    private var silenceJudged: Set<Int> = []
    private var droppedSilent = 0
    private var openingIndex: Int?
    private var openingDrops: [EdgeSentenceGuard.Drop] = []
    private var tailJudged = false
    private var tailDrops: [EdgeSentenceGuard.Drop] = []
    private var rejoinTask: Task<Void, Never>?
    private var rejoins = 0
    private let onGroqRateLimit: (@Sendable (GroqRateLimit) -> Void)?
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
    private var cancelled = false

    public init(transport: HTTPTransport, apiKey: @escaping @Sendable () throws -> String, prompt: String,
                fillerLeadIn: Bool = true, leadIn: String? = nil, firstMinimumSeconds: Double = 3.0, firstMaximumSeconds: Double = 4.0,
                hedgeAfterMs: Int = 700, finalSplitSeconds: Double? = nil,
                finalModel: String? = nil, rejoinGuard: Bool = false, lowSpeechGuard: Bool = false,
                edgeGuard: Bool = true,
                onChunkText: (@Sendable (Int, String) -> Void)? = nil,
                onGroqRateLimit: (@Sendable (GroqRateLimit) -> Void)? = nil,
                clock: any DictateClock = SystemClock()) {
        var client = TranscriptionClient(transport: transport, apiKey: apiKey)
        client.endpointURL = TranscriptionClient.groqEndpoint
        client.modelName = "whisper-large-v3-turbo"
        self.client = client
        self.hedgeAfterMs = max(0, hedgeAfterMs)
        self.clock = clock
        self.finalSplitSeconds = finalSplitSeconds
        // Cap only vocabulary: preserve the lead-in and the bounded previous tail.
        vocabulary = String(prompt.prefix(Vocabulary.maxPromptLength))
        self.leadIn = leadIn ?? (fillerLeadIn ? Self.fillerLeadIn : "")
        self.finalModel = finalModel
        self.rejoinGuard = rejoinGuard
        self.lowSpeechGuard = lowSpeechGuard
        self.edgeGuard = edgeGuard
        self.onGroqRateLimit = onGroqRateLimit
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
    /// Mark every piece returned by that caller's finish() with isFinal.
    @discardableResult
    public func submit(_ chunk: PauseChunker.Chunk, isFinal: Bool = false) -> Task<Void, Never>? {
        lock.withLock {
            guard !closed else { return nil }
            return enqueue(chunk, isFinal: isFinal)
        }
    }

    // Called with the lock held. Detached tasks never inherit the UI executor.
    @discardableResult
    private func enqueue(_ chunk: PauseChunker.Chunk, isFinal: Bool = false) -> Task<Void, Never> {
        if rejoinGuard { originalChunks[chunk.index] = chunk }
        let windows = LowSpeechSentenceGuard.windows(of: chunk.samples)
        windowsByIndex[chunk.index] = windows
        speechRatios[chunk.index] = windows.isEmpty ? 0 :
            Double(CaptureEvidence.speechWindows(windows).filter { $0 }.count) / Double(windows.count)
        let model = isFinal ? finalModel ?? client.modelName : client.modelName
        let task = Task.detached { [self] in await upload(chunk, model: model, isFinal: isFinal) }
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
            // v1.11: an output sits on an input (phase 0) or halfway between two (phase 0.5); the
            // taps for both phases are computed once, with the same formula, in the same order.
            let taps = position == Double(center) ? resampleTaps.whole : resampleTaps.half
            var sum = 0.0, weight = 0.0
            for (offset, coefficient) in taps {
                let input = center + offset
                sum += Double(pcm[min(pcm.count - 1, max(0, input))]) * coefficient
                weight += coefficient
            }
            return Int16(clamping: Int((sum / weight).rounded()))
        }
    }

    /// (input offset from the output's center, coefficient) for each phase, in input order.
    private static let resampleTaps: (whole: [(Int, Double)], half: [(Int, Double)]) = {
        func taps(phase: Double) -> [(Int, Double)] {
            (-15...16).compactMap { offset in
                let distance = Double(offset) - phase
                guard abs(distance) < 16 else { return nil }
                let x = distance * (2.0 / 3.0)
                let sinc = abs(x) < 1e-10 ? 1 : sin(.pi * x) / (.pi * x)
                return (offset, (2.0 / 3.0) * sinc * (0.5 + 0.5 * cos(.pi * distance / 16)))
            }
        }
        return (taps(phase: 0), taps(phase: 0.5))
    }()

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
            onGroqRateLimit?(GroqRateLimit(response: response, endpoint: .stt))
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
        let timer: Task<Void, Never>? = hedged ? Task.detached { [clock, hedgeAfterMs] in
            do {
                try await clock.sleep(until: clock.now().advanced(by: .milliseconds(hedgeAfterMs)))
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

    private func upload(_ chunk: PauseChunker.Chunk, model: String, isFinal: Bool) async {
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
                    return (leadIn.isEmpty ? "" : leadIn + " ") + vocabulary +
                           (tail.isEmpty ? "" : " " + tail)
                }
                var requestClient = client
                requestClient.modelName = model
                let request = requestClient.makeRequest(wav: wav, prompt: prompt, apiKey: key,
                                                 boundary: "dictate-\(UUID().uuidString)", includeEmptyPrompt: true)
                outcome = await requestAttempt(request, hedged: attempt == 1)
            } catch {
                outcome = AttemptResult(text: nil, status: nil, hedgeFired: false, winningRequest: nil)
            }
            if Task.isCancelled { return }
            lock.withLock {
                calls.append(Call(index: chunk.index, attempt: attempt, model: model, isFinal: isFinal, isRejoin: false, milliseconds: Self.ms(from: start),
                                  status: outcome.status, hedgeFired: outcome.hedgeFired,
                                  winningRequest: outcome.winningRequest))
                if let text = outcome.text { texts[chunk.index] = text }
                else if attempt == 2 { failures.insert(chunk.index) }
            }
            if let text = outcome.text {
                // v1.10 L3: the incremental cleaner cleans a chunk once the next one arrives, so a
                // low-speech chunk's dropped sentence is replaced BEFORE the next chunk is emitted.
                // v1.11 L1: a chunk with no speech, or the opening's invented sentence, is removed
                // before the text is ever streamed.
                let (replacements, current) = lock.withLock {
                    silenceLocked(chunk.index)
                    openingLocked(chunk.index)
                    let replaced = [chunk.index - 1, chunk.index].compactMap { index in guardLocked(index).map { (index, $0) } }
                    return (replaced, texts[chunk.index] ?? text)
                }
                for (index, filtered) in replacements where index < chunk.index { onChunkText?(index, filtered) }
                onChunkText?(chunk.index, current)
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
                for chunk in final where final.count > 1 || chunk.samples.count >= 7_200 { enqueue(chunk, isFinal: true) }
            }
            return tasks
        }
        for task in pending { await task.value }
        // No candidate boundary -> no task and no extra await on the hot path.
        let guardTask: Task<Void, Never>? = lock.withLock {
            if let rejoinTask { return rejoinTask }
            guard rejoinGuard, !cancelled else { return nil }
            let plan = plannedRejoins()
            guard !plan.isEmpty else { originalChunks.removeAll(); return nil }
            let task = Task.detached { [self] in await rejoinBoundaries(plan) }
            rejoinTask = task
            return task
        }
        await guardTask?.value
        // v1.11 L1: the last chunk's invented ending, judged once every chunk (and rejoin) is in.
        // The incremental cleaner holds the last chunk back until its own finish, which runs after.
        if let (index, filtered) = lock.withLock({ tailLocked() }) { onChunkText?(index, filtered) }
        return lock.withLock {
            let start = finishAt!
            let lastMs = lastResponse.map { $0 > start ? Int(($0 - start) / 1_000_000) : 0 } ?? 0
            for index in texts.keys.sorted() { _ = guardLocked(index) }
            let dropped = droppedByIndex.values.reduce(0, +)
            return Result(text: texts.keys.sorted().compactMap { texts[$0] }.filter { !$0.isEmpty }.joined(separator: " "),
                          chunks: tasks.count, rejoins: rejoins, failedCount: failures.count, lastChunkMs: lastMs,
                          sttMs: Self.ms(from: start), calls: calls,
                          hedges: calls.filter { $0.hedgeFired }.count,
                          hedgeWins: calls.filter { $0.winningRequest == 2 }.count, rateLimits: limits,
                          droppedLowSpeechSentences: dropped,
                          droppedTailSentences: tailDrops.filter { $0 == .lowSpeech }.count,
                          droppedOpeningSentences: openingDrops.filter { $0 == .lowSpeech }.count,
                          droppedArtifacts: (tailDrops + openingDrops).filter { $0 == .artifact }.count,
                          droppedSilentChunks: droppedSilent)
        }
    }

    /// The first non-empty text after `index`, or nil while an index between them is still in flight.
    private func adjacentNextTextLocked(after index: Int) -> String? {
        guard let last = windowsByIndex.keys.max(), last > index else { return nil }
        for candidate in (index + 1)...last {
            if failures.contains(candidate) { continue }
            guard let text = texts[candidate] else { return nil }
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Every window of the dictation so far: the reference its contrast threshold is taken from.
    private var referenceWindowsLocked: [Float] {
        windowsByIndex.keys.sorted().flatMap { windowsByIndex[$0] ?? [] }
    }

    /// v1.11 L1: empties chunk `index` when none of its windows is speech by the dictation's rule. Lock held.
    private func silenceLocked(_ index: Int) {
        guard edgeGuard, !silenceJudged.contains(index), let windows = windowsByIndex[index],
              let text = texts[index], !text.isEmpty else { return }
        silenceJudged.insert(index)
        guard EdgeSentenceGuard.isSilent(windows, reference: referenceWindowsLocked) else { return }
        texts[index] = ""
        droppedSilent += 1
    }

    /// v1.11 L1: the dictation's first chunk (index 0) loses an invented opening sentence when its
    /// text arrives. Lock held.
    private func openingLocked(_ index: Int) {
        guard edgeGuard, index == 0, openingIndex == nil, let text = texts[index], !text.isEmpty,
              let windows = windowsByIndex[index] else { return }
        openingIndex = index
        let result = EdgeSentenceGuard.filter(text, edge: .opening, windows: windows, reference: referenceWindowsLocked)
        guard !result.drops.isEmpty else { return }
        texts[index] = result.text
        openingDrops = result.drops
    }

    /// v1.11 L1: judges the last chunk's ending (a rejoined last pair as one) once. Returns the
    /// replacement text when a sentence was dropped. A chunk whose opening was already cut is left
    /// alone (its letters no longer match its audio). Lock held.
    private func tailLocked() -> (Int, String)? {
        guard edgeGuard, !cancelled, !tailJudged, var index = windowsByIndex.keys.max() else { return nil }
        tailJudged = true
        while rejoined.contains(index) { index -= 1 }
        guard let text = texts[index], !text.isEmpty, let windows = windowsByIndex[index],
              !(index == openingIndex && !openingDrops.isEmpty) else { return nil }
        let result = EdgeSentenceGuard.filter(text, edge: .tail, windows: windows, reference: referenceWindowsLocked)
        guard !result.drops.isEmpty else { return nil }
        texts[index] = result.text
        tailDrops = result.drops
        return (index, result.text)
    }

    /// v1.10 L3: judges chunk `index` once its next non-empty chunk text is known (the last chunk
    /// never is). Stores the filtered text and returns it when a sentence was dropped. Lock held.
    /// v1.11 L1: the comparator is the ADJACENT next text: every index after `index` up to it must
    /// have arrived (or failed), so a later chunk that answers early never stands in for it.
    private func guardLocked(_ index: Int) -> String? {
        guard lowSpeechGuard, index >= 0, !guarded.contains(index), let text = texts[index], !text.isEmpty,
              let next = adjacentNextTextLocked(after: index)
        else { return nil }
        guarded.insert(index)
        // A chunk without a measured ratio is never treated as low speech.
        let result = LowSpeechSentenceGuard.filter(text, speechRatio: speechRatios[index] ?? 1,
                                                   vocabulary: vocabulary, nextText: next)
        guard result.dropped > 0 else { return nil }
        texts[index] = result.text
        droppedByIndex[index] = result.dropped
        return result.text
    }

    /// Boundary indices (the current chunk of each pair) worth one pair request. Adjacent ORIGINAL
    /// chunks only: a chunk in one planned pair is never reused in another. Called with the lock held.
    private func plannedRejoins() -> [Int] {
        var consumed: Set<Int> = []
        var plan: [Int] = []
        for index in originalChunks.keys.sorted() where index >= 1 && plan.count < Self.maxRejoins {
            guard !consumed.contains(index - 1), !consumed.contains(index),
                  !failures.contains(index - 1), !failures.contains(index),
                  let previous = originalChunks[index - 1], originalChunks[index] != nil,
                  let before = texts[index - 1], let after = texts[index],
                  Self.shouldRejoin(previous: before, current: after,
                                    cutKind: previous.cutKind, quietRunMs: previous.quietRunMs) else { continue }
            consumed.formUnion([index - 1, index])
            plan.append(index)
        }
        return plan
    }

    /// One request per planned boundary, no hedge or retry. A failure leaves both chunks intact; a
    /// success replaces them (joined text on index-1, "" on index) and re-emits both through
    /// onChunkText so the incremental cleaner can drop anything it already cleaned from them.
    private func rejoinBoundaries(_ plan: [Int]) async {
        let snapshot = lock.withLock { (originalChunks, texts) }
        for index in plan {
            guard !Task.isCancelled, !lock.withLock({ cancelled }),
                  let previous = snapshot.0[index - 1], let current = snapshot.0[index] else { continue }
            let start = DispatchTime.now().uptimeNanoseconds
            let model = client.modelName
            let response: Response
            do {
                let key = try client.apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw TranscriptionError.missingKey }
                let wav = WAVEncoder.encode(samples: Self.resampleTo16k(previous.samples + current.samples), sampleRate: 16_000)
                let tail = snapshot.1[index - 2].map { String($0.suffix(200)) } ?? ""
                let prompt = (leadIn.isEmpty ? "" : leadIn + " ") + vocabulary + (tail.isEmpty ? "" : " " + tail)
                let request = client.makeRequest(wav: wav, prompt: prompt, apiKey: key,
                    boundary: "dictate-\(UUID().uuidString)", includeEmptyPrompt: true)
                response = await send(request) // Exactly one request, no hedge or retry.
            } catch { response = Response(text: nil, http: nil) }
            guard !Task.isCancelled else { return }
            let joined: String? = lock.withLock {
                rejoins += 1
                calls.append(Call(index: index, attempt: 1, model: model, isFinal: false, isRejoin: true,
                                  milliseconds: Self.ms(from: start), status: response.http?.statusCode,
                                  hedgeFired: false, winningRequest: response.text == nil ? nil : 1))
                if let http = response.http { limits = RateLimits(response: http) }
                lastResponse = DispatchTime.now().uptimeNanoseconds
                guard let text = response.text, !text.isEmpty else { return nil }
                texts[index - 1] = text
                texts[index] = ""
                if let previousRatio = speechRatios[index - 1], let currentRatio = speechRatios[index] {
                    speechRatios[index - 1] = min(previousRatio, currentRatio)
                }
                windowsByIndex[index - 1, default: []] += windowsByIndex[index] ?? []
                windowsByIndex[index] = []
                rejoined.insert(index)
                guarded.remove(index - 1)          // the joined text is judged afresh at finish
                droppedByIndex[index - 1] = nil
                return text
            }
            if let joined {
                onChunkText?(index - 1, joined)
                onChunkText?(index, "")
            }
        }
        lock.withLock { originalChunks.removeAll() }
    }

    public func cancel() {
        lock.withLock {
            closed = true
            cancelled = true
            originalChunks.removeAll()
            for task in tasks { task.cancel() }
            rejoinTask?.cancel()
            _ = chunker.finish()
        }
    }

    private static func ms(from start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}
