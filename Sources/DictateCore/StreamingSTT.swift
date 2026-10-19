import Foundation

/// v1.19 (ST1): what any streaming STT provider hands the host's finalization pipeline.
/// Provider-neutral: final text, how many ordered final segments built it, whether the provider
/// confirmed terminal completion, and counts/reasons-only diagnostics (never words, never keys).
public struct StreamingSTTResult: Sendable, Equatable {
    public struct Diagnostics: Sendable, Equatable {
        public var provider: String
        public var connects = 0
        public var interimFrames = 0
        public var duplicateFinals = 0
        public var finalsBeforeStop = 0
        public var lateFinals = 0
        public var closeStreams = 0
        /// Virtual ms from CloseStream to terminal completion; nil when it never completed.
        public var terminalMs: Int?
        /// missing_key | connect | socket | timeout | terminal_timeout | cancelled
        public var failureReason: String?
        public init(provider: String) { self.provider = provider }
    }

    public let text: String
    public let finalSegments: Int
    /// True only when the provider confirmed the end of the stream and nothing failed.
    /// Anything else is incomplete: the host must recover from the whole recording.
    public let complete: Bool
    public let diagnostics: Diagnostics

    public init(text: String, finalSegments: Int, complete: Bool, diagnostics: Diagnostics) {
        self.text = text
        self.finalSegments = finalSegments
        self.complete = complete
        self.diagnostics = diagnostics
    }

    /// Counts and reasons only, for the timeline line.
    public var fields: String {
        var line = "stt_provider=\(diagnostics.provider) stream_complete=\(complete ? 1 : 0) final_segments=\(finalSegments)"
            + " stream_duplicates=\(diagnostics.duplicateFinals) stream_late_finals=\(diagnostics.lateFinals)"
            + " stream_terminal_ms=\(diagnostics.terminalMs.map(String.init) ?? "-")"
        if let reason = diagnostics.failureReason { line += " stream_failure=\(reason)" }
        return line
    }
}

/// One recording's streaming STT session. `finish` flushes, closes and awaits terminal completion.
public protocol StreamingSTTSession: Sendable {
    func append(_ pcm: [Int16])
    func finish(at finish: DispatchTime) async -> StreamingSTTResult
    /// Stops every callback for this session; a later `finish` returns an incomplete result.
    func cancel()
}

/// v1.19: streaming finals are short segments, so a spoken stop phrase can arrive split across them
/// ("stop" | "dictation"). Retains the last few segments and asks `TrailingStopPhrase` about their join,
/// so the phrase must still stand as its own trailing sentence. Reports a match once.
public final class StreamingStopPhrase: @unchecked Sendable {
    /// Two segments for a two-word phrase, plus the one before it for the sentence-boundary check.
    public static let retainedSegments = 3
    private let lock = NSLock()
    private var tail: [String] = []
    private var fired = false

    public init() {}

    /// Appends one final segment; true exactly once, when the retained suffix ends with a stop phrase.
    public func append(_ segment: String) -> Bool {
        lock.withLock {
            tail.append(segment)
            if tail.count > Self.retainedSegments { tail.removeFirst(tail.count - Self.retainedSegments) }
            guard !fired, TrailingStopPhrase.endsDictation(tail.joined(separator: " ")) else { return false }
            fired = true
            return true
        }
    }
}

/// Pure offline word error rate (ST1 measurement): lowercase, split on non-alphanumerics,
/// word-level Levenshtein. No I/O.
public enum WordErrorRate {
    public struct Score: Sendable, Equatable {
        public let substitutions: Int
        public let deletions: Int
        public let insertions: Int
        public let referenceWords: Int
        public var wer: Double {
            let errors = substitutions + deletions + insertions
            guard referenceWords > 0 else { return Double(errors) }
            return Double(errors) / Double(referenceWords)
        }
        public var line: String {
            "S=\(substitutions) D=\(deletions) I=\(insertions) N=\(referenceWords) WER=" + String(format: "%.6f", wer)
        }
    }

    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public static func score(reference: String, hypothesis: String) -> Score {
        let ref = words(reference), hyp = words(hypothesis)
        let n = ref.count, m = hyp.count
        // cost[i][j]: edits turning ref[0..<i] into hyp[0..<j].
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let diagonal = cost[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                    cost[i][j] = min(diagonal, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        // Backtrace: prefer match/substitution, then deletion, then insertion.
        var s = 0, d = 0, ins = 0, i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1) {
                if ref[i - 1] != hyp[j - 1] { s += 1 }
                i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                d += 1; i -= 1
            } else {
                ins += 1; j -= 1
            }
        }
        return Score(substitutions: s, deletions: d, insertions: ins, referenceWords: n)
    }
}
