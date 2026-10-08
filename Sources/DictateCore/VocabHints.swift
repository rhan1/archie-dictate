import Foundation

/// Ordered, editable phonetic hints shared by every cleanup path.
public enum VocabHints {
    public static func parse(_ text: String) -> [(term: String, aliases: [String])] {
        text.components(separatedBy: .newlines).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.range(of: " <- ") else { return nil }
            let term = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let aliases = line[separator.upperBound...].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard !term.isEmpty, !aliases.isEmpty else { return nil }
            return (term, aliases)
        }
    }

    public static func promptSentence(_ hints: [(term: String, aliases: [String])]) -> String {
        guard !hints.isEmpty else { return "" }
        let entries = hints.map { hint in
            hint.aliases.map { "\"\($0)\"" }.joined(separator: " / ") + " → " + hint.term
        }
        return "Speech recognition often mishears names; when a word or phrase sounds like one of these, write the term: "
            + entries.joined(separator: ", ") + "."
    }
}
