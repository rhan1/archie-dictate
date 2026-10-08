import Foundation

/// Guard against the STT model returning its vocabulary list instead of the
/// speech (seen live 2026-10-09 00:27: 118 chars pasted == the 118-char prompt).
public enum PromptEcho {
    public static let threshold = 0.6

    /// True when `text`, normalised, is the vocabulary list, or contains at
    /// least 60 % of the list's comma-separated terms.
    public static func isEcho(_ text: String, vocabulary: String) -> Bool {
        let terms = vocabulary.split(separator: ",").map { normalise(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return false }
        let normalisedText = normalise(text)
        if normalisedText == terms.joined(separator: " ") { return true }
        let words = Set(normalisedText.split(separator: " ").map(String.init))
        let hits = terms.filter { term in
            term.split(separator: " ").allSatisfy { words.contains(String($0)) }
        }.count
        return Double(hits) / Double(terms.count) >= threshold
    }

    static func normalise(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
