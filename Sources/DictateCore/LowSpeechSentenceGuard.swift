import Foundation

/// Filters unlikely long sentences from chunks that contain very little speech.
public enum LowSpeechSentenceGuard {
    public static let maxSpeechRatio = 0.25
    public static let minWords = 4

    /// The fraction of 50 ms sample windows that meet CaptureEvidence's speech rule (`speechWindows`).
    public static func speechRatio(of samples: [Int16]) -> Double {
        let windowFrames = CaptureEvidence.windowFrames
        var windows: [Float] = []
        var start = 0
        while start < samples.count {
            let end = min(start + windowFrames, samples.count)
            let count = end - start
            guard count == windowFrames || count >= windowFrames / 2 else { break }
            var sum = 0.0
            for sample in samples[start..<end] {
                let normalized = Double(sample) / 32_768.0
                sum += normalized * normalized
            }
            windows.append(Float((sum / Double(count)).squareRoot()))
            start = end
        }
        guard !windows.isEmpty else { return 0 }
        // The same rule as `speech_sections` (v1.10 L2), judged within this chunk.
        let speech = CaptureEvidence.speechWindows(windows).filter { $0 }.count
        return Double(speech) / Double(windows.count)
    }

    public static func filter(_ text: String, speechRatio: Double, vocabulary: String,
                              nextText: String?) -> (text: String, dropped: Int) {
        guard speechRatio < maxSpeechRatio, let nextText else { return (text, 0) }
        let sentences = sentences(in: text)
        guard !sentences.isEmpty else { return (text, 0) }
        let known = contentWords(in: vocabulary).union(contentWords(in: nextText))
        let drop = sentences.map { sentence -> Bool in
            let words = words(in: sentence)
            let content = Set(words.filter { $0.count >= 3 && !stopWords.contains($0) })
            return words.count >= minWords && !content.isEmpty && content.isDisjoint(with: known)
        }
        guard drop.contains(false) else { return (text, 0) }
        let kept = zip(sentences, drop).compactMap { sentence, shouldDrop in
            shouldDrop ? nil : sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                drop.filter { $0 }.count)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "you", "are", "was", "but", "not", "with", "this", "that", "have",
        "from", "they", "will", "what", "your", "can", "our", "its", "just", "get", "got", "going",
        "gonna", "i'm", "it's", "let's", "one", "two", "all", "out", "now", "then", "than", "there",
        "here", "also", "into", "about", "been", "were", "would", "could", "should", "um", "uh", "hey",
        "okay", "ok", "so", "yeah", "like", "know", "think"
    ]

    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "?" || character == "!" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func contentWords(in text: String) -> Set<String> {
        Set(words(in: text).filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    private static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) ||
                scalar == "'" || scalar == "’" {
                current.unicodeScalars.append(scalar == "’" ? "'" : scalar)
            } else if !current.isEmpty {
                result.append(current.lowercased())
                current = ""
            }
        }
        if !current.isEmpty { result.append(current.lowercased()) }
        return result
    }
}
