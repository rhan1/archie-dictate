import Foundation

/// One serial cleanup lane per dictation. The synchronous chunk hook stores
/// out-of-order arrivals under a lock; only contiguous text is ever cleaned.
public final class IncrementalCleaner: @unchecked Sendable {
    public struct Result: Sendable {
        public let text: String?
        public let mode: String
        public let calls: Int
        public let stats: TranscriptCleaner.Stats?
    }

    private let lock = NSLock()
    private let cleaner: TranscriptCleaner
    private var chunks: [Int: String] = [:]
    private var contiguous = 0
    private var covered = 0 // Exclusive chunk index of the cleaned prefix.
    private var prefix = ""
    private var calls = 0
    private var failed = false
    private var closed = false
    private var cancelled = false
    private var pending: Task<Void, Never>?
    private var finalTask: Task<Result, Never>?

    public init(cleaner: TranscriptCleaner) { self.cleaner = cleaner }
    public var needsFallback: Bool { lock.withLock { failed } }
    public var callCount: Int { lock.withLock { calls } }

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
        guard !closed, !failed, pending == nil,
              end - covered >= (covered == 0 ? 1 : 2) else { return }
        let text = raw(from: covered, to: end)
        let context = prefix
        calls += 1
        pending = Task.detached { [self] in
            do {
                let output = try await cleaner.cleanIncrementalWithStats(text, context: context, final: false)
                lock.withLock {
                    if !cancelled {
                        prefix = Self.join(prefix: prefix, revision: nil, tail: output.text)
                        covered = end
                    }
                    pending = nil
                    schedule()
                }
            } catch {
                lock.withLock {
                    failed = true
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
    public func finish(totalChunks: Int) async -> Result {
        let task = lock.withLock {
            if let finalTask { return finalTask }
            closed = true
            let inFlight = pending
            let task = Task.detached { [self] in
                await inFlight?.value
                let tail: (String, String)? = lock.withLock {
                    guard !failed, !cancelled, totalChunks > 2, contiguous == totalChunks, !prefix.isEmpty else {
                        if totalChunks > 2, contiguous != totalChunks { failed = true }
                        return nil
                    }
                    calls += 1
                    return (raw(from: covered, to: totalChunks), prefix)
                }
                guard let (text, context) = tail else { return snapshot(text: nil, stats: nil) }
                do {
                    let output = try await cleaner.cleanIncrementalWithStats(text, context: context, final: true)
                    return lock.withLock {
                        result(text: cancelled ? nil : Self.join(prefix: prefix, revision: output.revision, tail: output.text),
                               stats: output.stats)
                    }
                } catch {
                    lock.withLock { failed = true }
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
               calls: calls, stats: stats)
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
    public static func join(prefix: String, revision: String?, tail: String) -> String {
        var prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if let revision {
            let chars = Array(prefix)
            var start = 0
            for index in chars.indices where ".?!".contains(chars[index]) {
                if index + 1 < chars.count, chars[index + 1] == " " {
                    var next = index + 1
                    while next < chars.count, chars[next] == " " { next += 1 }
                    if next < chars.count { start = next }
                }
            }
            prefix = String(chars.prefix(start)) + revision
        }
        return (prefix + " " + tail).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
