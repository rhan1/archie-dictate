import Foundation

/// A spoken way to end a dictation: "stop dictation", "archie stop" or "end dictation" said as the
/// LAST sentence of the transcript. It ends the dictation and is not pasted.
///
/// Conservative by construction, because stripping a real word out of someone's text is worse than
/// leaving a command in it:
///  - the phrase must end the text (trailing punctuation and spaces aside);
///  - it must stand as its own sentence: the text before it is empty or ends with `.` `!` `?` `…`
///    or a newline. "I told him to stop dictation." and "He said, stop dictation." are text;
///  - the phrase's words may be separated only by spaces and commas, with no sentence break inside.
/// Pure text in, text out: nothing is logged and no words leave this function.
public enum TrailingStopPhrase {
    public static let phrases = ["stop dictation", "archie stop", "end dictation"]

    public struct Result: Equatable, Sendable {
        /// The text without the phrase (trailing whitespace trimmed), or the input unchanged.
        public let text: String
        public let matched: Bool
    }

    public static func strip(_ text: String, phrases: [String] = TrailingStopPhrase.phrases) -> Result {
        let unchanged = Result(text: text, matched: false)
        let scalars = Array(text.unicodeScalars)
        var end = scalars.count
        // Trailing whitespace and punctuation after the phrase ("Stop dictation." / "...!").
        while end > 0, isFiller(scalars[end - 1]) { end -= 1 }
        guard end > 0 else { return unchanged }
        for phrase in phrases {
            let words = phrase.lowercased().split(separator: " ").map { Array($0.unicodeScalars) }
            guard !words.isEmpty else { continue }
            var cursor = end
            var ok = true
            for (position, word) in words.reversed().enumerated() {
                if position > 0 {
                    // Between two words of the phrase: spaces and commas only.
                    var sawSeparator = false
                    while cursor > 0, scalars[cursor - 1] == " " || scalars[cursor - 1] == "," || scalars[cursor - 1] == "\u{00A0}" {
                        cursor -= 1; sawSeparator = true
                    }
                    if !sawSeparator { ok = false; break }
                }
                guard cursor >= word.count else { ok = false; break }
                let candidate = scalars[(cursor - word.count)..<cursor]
                guard zip(candidate, word).allSatisfy({ lower($0) == $1 }) else { ok = false; break }
                cursor -= word.count
                // A word boundary: the character before must not be a letter or digit.
                if cursor > 0, isWordScalar(scalars[cursor - 1]) { ok = false; break }
            }
            guard ok else { continue }
            // What precedes the phrase must be a sentence boundary (or nothing).
            var before = cursor
            while before > 0, scalars[before - 1].properties.isWhitespace { before -= 1 }
            if before > 0 {
                let previous = scalars[before - 1]
                guard previous == "." || previous == "!" || previous == "?" || previous == "\u{2026}"
                        || scalars[before..<cursor].contains(where: { $0 == "\n" }) else { continue }
            }
            var kept = String(String.UnicodeScalarView(scalars[0..<before]))
            while let last = kept.unicodeScalars.last, last.properties.isWhitespace { kept.unicodeScalars.removeLast() }
            return Result(text: kept, matched: true)
        }
        return unchanged
    }

    /// True when this (chunk) text is, or ends with, a standalone stop phrase.
    public static func endsDictation(_ text: String) -> Bool { strip(text).matched }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(s) || CharacterSet.decimalDigits.contains(s) || s == "'" || s == "\u{2019}"
    }

    private static func isFiller(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || (!isWordScalar(s) && (CharacterSet.punctuationCharacters.contains(s) || CharacterSet.symbols.contains(s)))
    }

    private static func lower(_ s: Unicode.Scalar) -> Unicode.Scalar {
        s.properties.lowercaseMapping.unicodeScalars.first ?? s
    }
}
