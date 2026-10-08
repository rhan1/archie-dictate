import Foundation

/// One serial cleanup lane per dictation. The synchronous chunk hook stores
/// out-of-order arrivals under a lock; only contiguous text is ever cleaned.
public final class IncrementalCleaner: @unchecked Sendable {
    public struct Result: Sendable {
        public let text: String?
        public let mode: String
        public let calls: Int
        public let stats: TranscriptCleaner.Stats?
        /// Why incremental mode fell back (labels only, never text).
        public let fallbackReason: String?
    }

    private let lock = NSLock()
    private let cleaner: TranscriptCleaner
    private var chunks: [Int: String] = [:]
    private var contiguous = 0
    private var covered = 0 // Exclusive chunk index of the cleaned prefix.
    private var prefix = ""
    private var calls = 0
    private var failed = false
    private var failure: String?
    private var closed = false
    private var sealed = false
    private var cancelled = false
    private var pending: Task<Void, Never>?
    private var finalTask: Task<Result, Never>?

    public init(cleaner: TranscriptCleaner) { self.cleaner = cleaner }
    public var needsFallback: Bool { lock.withLock { failed } }
    public var callCount: Int { lock.withLock { calls } }
    public var fallbackReason: String? { lock.withLock { failed ? failure : nil } }

    public func append(index: Int, text: String) {
        lock.withLock {
            guard !closed, !failed, index >= 0, chunks[index] == nil else { return }
            chunks[index] = text
            while chunks[contiguous] != nil { contiguous += 1 }
            schedule()
        }
    }

    // Lock held. Reserve both the task and its range before another arrival.
    private func schedule() {
        let end = max(0, contiguous - 2)
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
                    failed = true
                    failure = failure ?? "mid_" + ((error as? TranscriptionError)?.logReason ?? "error")
                    pending = nil
                }
            }
        }
    }

    private func raw(from start: Int, to end: Int) -> String {
        (start..<end).compactMap { chunks[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Await the current request (useful to pace deterministic fixture arrivals).
    public func waitForPending() async {
        let task = lock.withLock { pending }
        await task?.value
    }

    /// Seal before awaiting the current call, so queued speech is handled in
    /// exactly one final tail request. Repeated finish calls share that task.
    /// The finish tap: no new intermediate call may start (the final chunk's
    /// text lands after this); a call already in flight completes.
    public func seal() { lock.withLock { sealed = true } }

    public func finish(totalChunks: Int) async -> Result {
        let task = lock.withLock {
            if let finalTask { return finalTask }
            closed = true
            let inFlight = pending
            let task = Task.detached { [self] in
                await inFlight?.value
                let tail: (String, String)? = lock.withLock {
                    guard !failed, !cancelled, totalChunks > 2, contiguous == totalChunks, !prefix.isEmpty else {
                        if totalChunks > 2, contiguous != totalChunks { failed = true; failure = failure ?? "gap_\(contiguous)of\(totalChunks)" }
                        return nil
                    }
                    calls += 1
                    let sentence = Self.lastSentence(prefix)
                    let context = String(prefix.dropLast(sentence.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (sentence + " " + raw(from: covered, to: totalChunks), context)
                }
                guard let (text, context) = tail else { return snapshot(text: nil, stats: nil) }
                do {
                    let output = try await cleaner.cleanIncrementalWithStats(text, context: context, final: true)
                    return lock.withLock {
                        result(text: cancelled ? nil : Self.join(prefix: context, tail: output.text),
                               stats: output.stats)
                    }
                } catch {
                    lock.withLock { failed = true; failure = failure ?? "final_" + ((error as? TranscriptionError)?.logReason ?? "error") }
                    return snapshot(text: nil, stats: nil)
                }
            }
            finalTask = task
            return task
        }
        return await task.value
    }

    private func result(text: String?, stats: TranscriptCleaner.Stats?) -> Result {
        Result(text: text, mode: failed ? "incremental_fallback" : text == nil ? "single" : "incremental",
               calls: calls, stats: stats, fallbackReason: failed ? failure : nil)
    }
    private func snapshot(text: String?, stats: TranscriptCleaner.Stats?) -> Result {
        lock.withLock { result(text: text, stats: stats) }
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
