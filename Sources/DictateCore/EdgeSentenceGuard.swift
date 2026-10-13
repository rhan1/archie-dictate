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

    /// True when no window of `windows` may be speech by the dictation's floor.
    public static func isSilent(_ windows: [Float], reference: [Float]) -> Bool {
        !windows.isEmpty && !CaptureEvidence.possibleSpeechWindows(windows, reference: reference).contains(true)
    }

    /// Drops invented sentences at `edge` of one chunk. `windows` are that chunk's 50 ms RMS
    /// windows; `reference` is every window of the dictation so far.
    public static func filter(_ text: String, edge: Edge, windows: [Float], reference: [Float]) -> (text: String, drops: [Drop]) {
        let sentences = sentences(in: text)
        guard !sentences.isEmpty, !windows.isEmpty else { return (text, []) }
        let speech = CaptureEvidence.possibleSpeechWindows(windows, reference: reference)
        let sections = sections(speech)
        let words = runs(speech, minimum: minSpeechRun)
        let count = windows.count
        let windowSeconds = Double(CaptureEvidence.windowFrames) / CaptureEvidence.rate
        if let first = sections.first, let last = sections.last {
            let quiet = edge == .tail ? count - last.upperBound : first.lowerBound
            guard Double(quiet) * windowSeconds >= minEdgeSeconds - 0.000001 else { return (text, []) }
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
        for index in order.prefix(maxDrops) {
            let span = bounds[index]..<max(bounds[index] + 1, bounds[index + 1])
            let overlapsSpeech = (sections + words).contains { $0.overlaps(span) }
            guard !overlapsSpeech, ratio(speech[span.clamped(to: 0..<count)]) < maxSpeechRatio else { break }
            drops.append(artifacts.contains(normalized(sentences[index])) ? .artifact : .lowSpeech)
            dropped.insert(index)
        }
        guard !drops.isEmpty else { return (text, []) }
        let kept = sentences.indices.filter { !dropped.contains($0) }.map { sentences[$0] }
        return (kept.joined(separator: " "), drops)
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
