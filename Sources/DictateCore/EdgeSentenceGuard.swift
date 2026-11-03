import Foundation

/// v1.11 L1: Whisper's invented sentences at the edges of a dictation ("Thank you.", "Dictate."
/// after the last word; the same on the room noise before the first). 10-13 08:2x: "random words
/// get added at the end … a lot of times I notice a 'thank you', even though I didn't say it."
///
/// A sentence is dropped ONLY on audio evidence; uncertain text is kept. Groq returns no
/// timestamps, so each sentence is placed on the chunk's timeline by its letter count, and a
/// sentence is dropped only when all of these hold:
/// - its span overlaps no speech section and no speech-like run (≥ 150 ms of speech windows);
/// - its span's speech ratio is below 25 %;
/// - the edge holds at least `minEdgeSeconds` of non-speech beyond the first/last speech section
///   (with no section at all, the whole chunk's ratio is below 25 %): a short honest ending
///   followed by a key click must not map onto the click.
/// Audio is judged by `CaptureEvidence.possibleSpeechWindows`: anything 6 dB over the DICTATION's own
/// floor (or above −40 dBFS) may be speech, so a softly spoken word keeps its sentence.
/// Counts only; no text leaves this type.
public enum EdgeSentenceGuard {
    public enum Edge: Sendable { case opening, tail }
    public enum Drop: String, Sendable, Equatable { case lowSpeech, artifact }

    /// Whisper's known sentences on silence (and the vocabulary prompt's "Dictate"), compared
    /// lowercased with punctuation removed. A match is labelled an artifact; it is dropped by the
    /// same audio rule as any other sentence, never by its words alone.
    public static let artifacts: Set<String> = ["thank you", "thanks for watching", "dictate", "bye"]
    public static let maxSpeechRatio = 0.25
    public static let minEdgeSeconds = 1.0
    /// Speech windows in a row that count as a word even when they are shorter than a section.
    public static let minSpeechRun = 3
    /// At most this many sentences are dropped from one edge ("Thank you. Bye.").
    public static let maxDrops = 2

    /// v1.28 FR4-A: one recognizer segment (Groq `verbose_json` `segments[]`), seconds into the chunk's audio.
    public struct Segment: Sendable, Equatable, Decodable {
        public let start: Double
        public let end: Double
        public let text: String
        public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
    }

    /// True when no window of `windows` may be speech by the dictation's floor.
    public static func isSilent(_ windows: [Float], reference: [Float]) -> Bool {
        !windows.isEmpty && !CaptureEvidence.possibleSpeechWindows(windows, reference: reference).contains(true)
    }

    /// Drops invented sentences at `edge` of one chunk. `windows` are that chunk's 50 ms RMS
    /// windows; `reference` is every window of the dictation so far.
    /// v1.28 FR3-A: `leadingQuiet` = seconds of non-speech before this chunk (the emptied chunks of a silent lead-in),
    /// counted with the chunk's own lead for the opening's ≥ `minEdgeSeconds` test; `maxDrops` = the edge's budget left.
    /// v1.28 FR4-A: `afterSilentLeadIn` = this is the opening chunk and every chunk before it ended empty. There the
    /// letter-count placement is not used for general sentences (a chunk's lead is an arbitrary pause cut, so an honest
    /// short opening maps onto it): with the recognizer's `segments`, a sentence is dropped only when its segments'
    /// [start, end] overlaps no possible-speech window (so no speech-like run either); without segments (Apple, Scribe,
    /// or segments that do not match the text) only a known artifact (`artifacts`) may be dropped, by the letter rule.
    public static func filter(_ text: String, edge: Edge, windows: [Float], reference: [Float],
                              leadingQuiet: TimeInterval = 0, maxDrops dropBudget: Int = maxDrops,
                              afterSilentLeadIn: Bool = false, segments: [Segment]? = nil) -> (text: String, drops: [Drop]) {
        let sentences = sentences(in: text)
        guard !sentences.isEmpty, !windows.isEmpty else { return (text, []) }
        let speech = CaptureEvidence.possibleSpeechWindows(windows, reference: reference)
        let count = windows.count
        let windowSeconds = Double(CaptureEvidence.windowFrames) / CaptureEvidence.rate
        let leadIn = afterSilentLeadIn && edge == .opening
        if leadIn, let spans = segmentSpans(sentences, segments: segments) {
            var drops: [Drop] = []
            var dropped: Set<Int> = []
            for index in sentences.indices.prefix(max(0, dropBudget)) {
                let (start, end) = spans[index]
                let low = min(count - 1, max(0, Int((start / windowSeconds).rounded(.down))))
                let high = min(count, max(low + 1, Int((end / windowSeconds).rounded(.up))))
                guard !speech[low..<high].contains(true) else { break }
                drops.append(artifacts.contains(normalized(sentences[index])) ? .artifact : .lowSpeech)
                dropped.insert(index)
            }
            guard !drops.isEmpty else { return (text, []) }
            return (sentences.indices.filter { !dropped.contains($0) }.map { sentences[$0] }.joined(separator: " "), drops)
        }
        let sections = sections(speech)
        let words = runs(speech, minimum: minSpeechRun)
        if let first = sections.first, let last = sections.last {
            let quiet = edge == .tail ? count - last.upperBound : first.lowerBound
            let lead = edge == .opening ? leadingQuiet : 0
            guard Double(quiet) * windowSeconds + lead >= minEdgeSeconds - 0.000001 else { return (text, []) }
        } else {
            guard ratio(speech[...]) < maxSpeechRatio else { return (text, []) }
        }
        // Letter counts place each sentence on the chunk's timeline.
        let weights = sentences.map { max(1, $0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count) }
        let total = weights.reduce(0, +)
        var bounds: [Int] = [0]
        var through = 0
        for weight in weights {
            through += weight
            bounds.append(count * through / total)
        }
        bounds[bounds.count - 1] = count
        var drops: [Drop] = []
        var dropped: Set<Int> = []
        let order = edge == .tail ? Array(sentences.indices.reversed()) : Array(sentences.indices)
        for index in order.prefix(max(0, dropBudget)) {
            let span = bounds[index]..<max(bounds[index] + 1, bounds[index + 1])
            let overlapsSpeech = (sections + words).contains { $0.overlaps(span) }
            guard !overlapsSpeech, ratio(speech[span.clamped(to: 0..<count)]) < maxSpeechRatio else { break }
            if leadIn, !artifacts.contains(normalized(sentences[index])) { break }     // FR4-A: no segments → artifacts only
            drops.append(artifacts.contains(normalized(sentences[index])) ? .artifact : .lowSpeech)
            dropped.insert(index)
        }
        guard !drops.isEmpty else { return (text, []) }
        let kept = sentences.indices.filter { !dropped.contains($0) }.map { sentences[$0] }
        return (kept.joined(separator: " "), drops)
    }

    /// v1.28 FR4-A: each sentence's [start, end] in seconds from the segments its letters fall in (a segment that
    /// spans two sentences gives both its whole time: uncertain text is kept). Nil when there are no segments or
    /// their letters are not the text's letters (e.g. a repetition loop was collapsed).
    static func segmentSpans(_ sentences: [String], segments: [Segment]?) -> [(Double, Double)]? {
        guard let segments, !segments.isEmpty else { return nil }
        func letters(_ s: String) -> [Character] { Array(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let segmentLetters = segments.map { letters($0.text).count }
        let sentenceLetters = sentences.map { letters($0).count }
        guard segments.flatMap({ letters($0.text) }) == sentences.flatMap({ letters($0) }),
              segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }) else { return nil }
        var spans: [(Double, Double)] = []
        var sentenceStart = 0
        for sentence in sentenceLetters {
            let sentenceEnd = sentenceStart + max(1, sentence)
            var segmentStart = 0
            var start = Double.infinity, end = -Double.infinity
            for (index, length) in segmentLetters.enumerated() {
                let segmentEnd = segmentStart + length
                if length > 0, segmentStart < sentenceEnd, sentenceStart < segmentEnd {
                    start = min(start, segments[index].start)
                    end = max(end, segments[index].end)
                }
                segmentStart = segmentEnd
            }
            guard start.isFinite, end.isFinite else { return nil }
            spans.append((start, end))
            sentenceStart += sentence
        }
        return spans
    }

    /// Sentences, trimmed. A terminator ends one only before whitespace or the end ("1.11" stays whole).
    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if ".?!".contains(character), next.map({ $0.isWhitespace }) ?? true {
                result.append(current)
                current = ""
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func normalized(_ sentence: String) -> String {
        sentence.lowercased().unicodeScalars
            .filter { CharacterSet.letters.contains($0) || $0 == " " }
            .map(String.init).joined()
            .split(separator: " ").joined(separator: " ")
    }

    private static func ratio(_ speech: ArraySlice<Bool>) -> Double {
        speech.isEmpty ? 0 : Double(speech.filter { $0 }.count) / Double(speech.count)
    }

    /// Consecutive speech windows at least `minimum` long.
    static func runs(_ speech: [Bool], minimum: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (index, loud) in (speech + [false]).enumerated() {
            if loud { start = start ?? index }
            else if let first = start {
                if index - first >= minimum { result.append(first..<index) }
                start = nil
            }
        }
        return result
    }

    /// Speech sections as window ranges: the same rule as `speech_sections` (≥ 0.3 s from the first
    /// speech window to the last, closed by 0.2 s without speech).
    static func sections(_ speech: [Bool]) -> [Range<Int>] {
        let windowSeconds = Double(CaptureEvidence.windowFrames) / CaptureEvidence.rate
        let separation = Int((CaptureEvidence.minSeparation / windowSeconds).rounded(.up))
        var result: [Range<Int>] = []
        var first: Int?
        var last = 0
        func close() {
            if let start = first, Double(last + 1 - start) * windowSeconds >= CaptureEvidence.minSection - 0.000001 {
                result.append(start..<(last + 1))
            }
            first = nil
        }
        for (index, loud) in speech.enumerated() {
            if loud {
                if first == nil { first = index }
                last = index
            } else if first != nil, index - last >= separation {
                close()
            }
        }
        close()
        return result
    }
}
