import Foundation

/// One serial cleanup lane per dictation. Only contiguous arrivals are cleaned.
public final class IncrementalCleaner: @unchecked Sendable {
    /// The existing full-raw Groq → local → raw cleanup path, injected by the caller.
    public struct SingleResult: Sendable {
        public let text: String
        public let label: String
        public let model: String
        public let stats: TranscriptCleaner.Stats?
        public let calls: Int
        public init(text: String, label: String, model: String, stats: TranscriptCleaner.Stats?, calls: Int) {
            self.text = text; self.label = label; self.model = model; self.stats = stats; self.calls = calls
        }
    }
    public struct Result: Sendable {
        public let text: String?
        public let mode: String
        public let calls: Int
        public let stats: TranscriptCleaner.Stats?
        /// Labels only, never text.
        public let fallbackReason: String?
        public let skippedReason: String?
        public let single: SingleResult?
    }

    private let lock = NSLock()
    private let cleaner: TranscriptCleaner
    private let raceAfterMs: Int
    private let finalIncludeExamples: Bool
    private var chunks: [Int: String] = [:]
    private var contiguous = 0
    private var covered = 0
    private var prefix = ""
    private var calls = 0
    private var singleCalls = 0
    private var failed = false
    private var failure: String?
    private var closed = false
    private var sealed = false
    private var sealedAt: ContinuousClock.Instant?
    private var cancelled = false
    private var pending: Task<Void, Never>?
    private var finalTask: Task<Result, Never>?

    /// The final tail call omits the few-shot pairs by default (v1.5.1: ~80 ms faster on the
    /// user's fixture); the single-call path keeps them.
    public init(cleaner: TranscriptCleaner, raceAfterMs: Int = 600, finalIncludeExamples: Bool = false) {
        self.cleaner = cleaner
        self.finalIncludeExamples = finalIncludeExamples
        self.raceAfterMs = max(0, raceAfterMs)
    }
    public var needsFallback: Bool { lock.withLock { failed } }
    public var callCount: Int { lock.withLock { calls + singleCalls } }
    public var fallbackReason: String? { lock.withLock { failure } }

    public func append(index: Int, text: String) {
        lock.withLock {
            guard !closed, !failed, index >= 0, chunks[index] == nil else { return }
            chunks[index] = text
            while chunks[contiguous] != nil { contiguous += 1 }
            schedule()
        }
    }

    // Hold back just the last chunk. First batch starts with one cleanable
    // chunk; subsequent batches require at least two more.
    private func schedule() {
        let end = max(0, contiguous - 1)
        guard !closed, !sealed, !failed, pending == nil,
              end - covered >= (covered == 0 ? 1 : 2) else { return }
        let text = raw(from: covered, to: end)
        let context = prefix
        calls += 1
        pending = Task.detached { [self] in
            do {
                let output = try await cleaner.cleanIncrementalWithStats(text, context: context, final: false)
                lock.withLock {
                    if !cancelled {
                        prefix = (prefix + " " + output.text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                        covered = end
                    }
                    pending = nil
                    schedule()
                }
            } catch {
                lock.withLock {
                    if !cancelled {
                        failed = true
                        failure = failure ?? "mid_" + ((error as? TranscriptionError)?.logReason ?? "error")
                    }
                    pending = nil
                }
            }
        }
    }

    private func raw(from start: Int, to end: Int) -> String {
        (start..<end).compactMap { chunks[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    public func waitForPending() async { await lock.withLock { pending }?.value }

    /// The timer starts at the finish tap, before final STT supplies full raw text.
    public func seal() {
        lock.withLock {
            sealed = true
            if sealedAt == nil { sealedAt = .now }
        }
    }

    /// Repeated finish calls share one task. Supplying a single path enables
    /// the finish race; fixture callers can still exercise incremental alone.
    public func finish(totalChunks: Int, rawText: String? = nil,
                       single: (@Sendable (String) async -> SingleResult)? = nil) async -> Result {
        let task = lock.withLock {
            if let finalTask { return finalTask }
            closed = true
            sealed = true
            if sealedAt == nil { sealedAt = .now }
            let inFlight = pending
            let deadline = sealedAt!.advanced(by: .milliseconds(raceAfterMs))
            let task = Task.detached { [self] in
                await finishPaths(totalChunks: totalChunks, inFlight: inFlight, deadline: deadline,
                                  rawText: rawText, single: single)
            }
            finalTask = task
            return task
        }
        return await task.value
    }

    private enum FinishEvent: Sendable {
        case deadline
        case incremental(Result)
        case single(SingleResult)
    }

    private func finishPaths(totalChunks: Int, inFlight: Task<Void, Never>?, deadline: ContinuousClock.Instant,
                             rawText: String?, single: (@Sendable (String) async -> SingleResult)?) async -> Result {
        // No intermediate is useful for a <=2-chunk utterance, even if chunk
        // one arrived early enough to start it before we knew the total.
        if totalChunks <= 2 {
            lock.withLock { cancelled = true }
            inFlight?.cancel()
            return await singleOrSnapshot(rawText: rawText, single: single, mode: "single", skipped: "short")
        }
        guard let rawText, let single else {
            return await finishIncremental(totalChunks: totalChunks, inFlight: inFlight)
        }
        let (events, continuation) = AsyncStream<FinishEvent>.makeStream()
        let incrementalPath = Task.detached { [self] in
            continuation.yield(.incremental(await finishIncremental(totalChunks: totalChunks, inFlight: inFlight)))
        }
        let timer: Task<Void, Never>? = inFlight != nil ? Task.detached {
            do {
                try await ContinuousClock().sleep(until: deadline)
                if !Task.isCancelled { continuation.yield(.deadline) }
            } catch {}
        } : nil
        var singlePath: Task<Void, Never>?
        var raced = false
        var skipped: String?
        var incrementalDone = false
        func startSingle() {
            guard singlePath == nil else { return }
            lock.withLock { singleCalls = 1 }
            singlePath = Task.detached {
                continuation.yield(.single(await single(rawText)))
            }
        }
        defer {
            continuation.finish()
            timer?.cancel()
            singlePath?.cancel()
            incrementalPath.cancel()
            inFlight?.cancel()
        }
        for await event in events {
            switch event {
            case .deadline:
                // A finished mid request does not trigger a hedge of the final.
                let stillPending = lock.withLock { pending != nil && !failed && !cancelled }
                if stillPending {
                    raced = true
                    lock.withLock { failure = failure ?? "mid_slow_at_finish" }
                    startSingle()
                }
            case .incremental(let output):
                incrementalDone = true
                if let text = output.text {
                    return snapshot(text: text, stats: output.stats,
                                    mode: raced ? "race_incremental" : output.mode)
                }
                skipped = output.skippedReason
                startSingle() // Already failed: immediately, without waiting for timer.
            case .single(let output):
                lock.withLock {
                    singleCalls = output.calls
                    cancelled = true // Ignore late intermediate/final output.
                }
                let mode = raced ? "race_single" : lock.withLock { failed ? "incremental_fallback" : "single" }
                return snapshot(text: output.text, stats: output.stats, mode: mode,
                                skipped: incrementalDone ? skipped : nil, single: output)
            }
        }
        lock.withLock { cancelled = true }
        return snapshot(text: nil, stats: nil)
    }

    private func singleOrSnapshot(rawText: String?, single: (@Sendable (String) async -> SingleResult)?,
                                  mode: String, skipped: String?) async -> Result {
        guard let rawText, let single else { return snapshot(text: nil, stats: nil, mode: mode, skipped: skipped) }
        lock.withLock { singleCalls = 1 }
        let output = await single(rawText)
        lock.withLock { singleCalls = output.calls }
        return snapshot(text: output.text, stats: output.stats, mode: mode, skipped: skipped, single: output)
    }

    private func finishIncremental(totalChunks: Int, inFlight: Task<Void, Never>?) async -> Result {
        await inFlight?.value
        if Task.isCancelled { return snapshot(text: nil, stats: nil) }
        let tail: (String, String)? = lock.withLock {
            guard !failed, !cancelled, contiguous == totalChunks, !prefix.isEmpty else {
                if !cancelled, contiguous != totalChunks { failed = true; failure = failure ?? "gap_\(contiguous)of\(totalChunks)" }
                return nil
            }
            calls += 1
            let sentence = Self.lastSentence(prefix)
            let context = String(prefix.dropLast(sentence.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return (sentence + " " + raw(from: covered, to: totalChunks), context)
        }
        guard let (text, context) = tail else {
            return snapshot(text: nil, stats: nil, skipped: "none_cleanable_before_finish")
        }
        do {
            var finalCleaner = cleaner
            finalCleaner.includeExamples = finalIncludeExamples
            let output = try await finalCleaner.cleanIncrementalWithStats(text, context: context, final: true)
            return snapshot(text: lock.withLock { cancelled } ? nil : Self.join(prefix: context, tail: output.text), stats: output.stats)
        } catch {
            lock.withLock {
                if !cancelled {
                    failed = true
                    failure = failure ?? "final_" + ((error as? TranscriptionError)?.logReason ?? "error")
                }
            }
            return snapshot(text: nil, stats: nil)
        }
    }

    private func snapshot(text: String?, stats: TranscriptCleaner.Stats?, mode: String? = nil,
                          skipped: String? = nil, single: SingleResult? = nil) -> Result {
        lock.withLock {
            let mode = mode ?? (failed ? "incremental_fallback" : text == nil ? "single" : "incremental")
            return Result(text: text, mode: mode, calls: calls + singleCalls, stats: stats,
                          fallbackReason: failure, skippedReason: mode == "single" ? skipped : nil, single: single)
        }
    }

    public func cancel() {
        lock.withLock {
            closed = true
            cancelled = true
            pending?.cancel()
            finalTask?.cancel()
            chunks.removeAll()
            prefix = ""
        }
    }

    /// Sentence boundaries deliberately use only . ? ! followed by space/end.
    public static func lastSentence(_ text: String) -> String {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var start = 0
        for index in chars.indices where ".?!".contains(chars[index]) {
            if index + 1 < chars.count, chars[index + 1] == " " {
                var next = index + 1
                while next < chars.count, chars[next] == " " { next += 1 }
                if next < chars.count { start = next }
            }
        }
        return String(chars.dropFirst(start))
    }

    /// Drop the longest repeated boundary of up to three words at the final join.
    public static func join(prefix: String, tail: String) -> String {
        let prefixWords = prefix.split(whereSeparator: { $0.isWhitespace })
        var tailWords = tail.split(whereSeparator: { $0.isWhitespace })
        let normalise: (Substring) -> String = { $0.filter { !$0.isPunctuation }.lowercased() }
        for count in stride(from: min(3, prefixWords.count, tailWords.count), through: 1, by: -1) {
            let boundary = prefixWords.suffix(count).map(normalise)
            if boundary.allSatisfy({ !$0.isEmpty }), boundary == tailWords.prefix(count).map(normalise) {
                tailWords.removeFirst(count)
                break
            }
        }
        return (prefixWords + tailWords).joined(separator: " ")
    }
}
