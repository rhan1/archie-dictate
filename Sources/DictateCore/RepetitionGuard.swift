import Foundation

/// M2 (2026-10-18): Whisper repetition loops never reach the paste. On 2026-10-17 00:43 four seconds
/// of "testing" came back as 316 characters ("Lime, Ngo, Hori, … Ngo ×36 … Testing ×11"); cleanup then
/// failed on the network and the raw loop was pasted. Counts only leave this type (never text).
public enum RepetitionGuard {
    public struct Output: Equatable, Sendable {
        public let text: String
        /// Collapsed runs + dropped/reduced chunks (the `stt_dropped_loop=<n>` count).
        public let loops: Int
        public init(text: String, loops: Int) { self.text = text; self.loops = loops }
    }

    /// A run of this many identical words (case- and punctuation-insensitive) is a loop.
    public static let minimumRun = 4
    /// Speech rarely tops ~20 characters per second of audio; a loop is far above it.
    public static let maximumCharsPerSecond = 25.0
    /// The dominant-word rule needs at least this many words in the chunk.
    public static let minimumTokensForShare = 8

    private static let trailing = CharacterSet(charactersIn: ",.;:!?")

    private static func normalized(_ token: Substring) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Collapses every run of ≥ `minimumRun` identical words to one ("Ngo, Ngo, Ngo, Ngo" → "Ngo"),
    /// keeping the run's final punctuation. Runs of 2–3 ("no, no, no") and text without a run are
    /// returned byte-identical.
    public static func collapseRuns(_ text: String) -> Output {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let keys = tokens.map(normalized)
        var out: [String] = []
        var loops = 0
        var i = 0
        while i < tokens.count {
            var j = i + 1
            if !keys[i].isEmpty { while j < tokens.count && keys[j] == keys[i] { j += 1 } }
            if j - i >= minimumRun {
                let first = String(tokens[i])
                let core = String(first.unicodeScalars.reversed().drop { trailing.contains($0) }.reversed().map(Character.init))
                let suffix = String(String(tokens[j - 1]).unicodeScalars.reversed().prefix { trailing.contains($0) }.reversed().map(Character.init))
                out.append(core + suffix)
                loops += 1
            } else {
                out.append(contentsOf: tokens[i..<j].map(String.init))
            }
            i = j
        }
        guard loops > 0 else { return Output(text: text, loops: 0) }
        return Output(text: out.joined(separator: " "), loops: loops)
    }

    /// One chunk's text against its own audio. A loop chunk — more than `maximumCharsPerSecond`
    /// characters per second of audio, or ≥ 50 % one word over ≥ `minimumTokensForShare` words — is
    /// dropped, except a pure repetition of one word (≥ 90 %), which keeps that word once. Decision
    /// (conservative, never delete real words): the rate rule alone drops a chunk only when it also
    /// shows repetition (a run of ≥ `minimumRun` or ≥ 30 % one word); a fast but varied chunk is kept.
    public static func guardChunk(_ text: String, audioSeconds: Double) -> Output {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(normalized).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return Output(text: text, loops: 0) }
        var counts: [String: Int] = [:]
        tokens.forEach { counts[$0, default: 0] += 1 }
        let share = Double(counts.values.max() ?? 0) / Double(tokens.count)
        let collapsed = collapseRuns(text)
        let fast = audioSeconds > 0 && Double(text.count) / audioSeconds > maximumCharsPerSecond
        let dominated = tokens.count >= minimumTokensForShare && share >= 0.5
        let repetitive = collapsed.loops > 0 || share >= 0.3
        guard dominated || (fast && repetitive) else { return collapsed }
        if share >= 0.9 { return Output(text: collapsed.text, loops: max(1, collapsed.loops)) }
        return Output(text: "", loops: 1)
    }
}
