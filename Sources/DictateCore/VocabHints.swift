import Foundation

/// Ordered, editable phonetic hints shared by every cleanup path.
public enum VocabHints {
    public static func parse(_ text: String) -> [(term: String, aliases: [String])] {
        text.components(separatedBy: .newlines).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            guard let separator = line.range(of: "<-") else { return (line, []) }
            let term = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let aliases = line[separator.upperBound...].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard !term.isEmpty else { return nil }
            return (term, aliases)
        }
    }

    /// An existing user file always wins, including an empty or unreadable file.
    public static func load(
        fileURL: URL = AppPaths().vocabularyURL,
        bundledURL: URL? = Bundle.main.url(forResource: "vocab-hints.sample", withExtension: "txt")
    ) -> [(term: String, aliases: [String])] {
        let url = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : bundledURL
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    public static func promptSentence(_ hints: [(term: String, aliases: [String])]) -> String {
        let phoneticHints = hints.filter { !$0.aliases.isEmpty }
        guard !phoneticHints.isEmpty else { return "" }
        let entries = phoneticHints.map { hint in
            hint.aliases.map { "\"\($0)\"" }.joined(separator: " / ") + " → " + hint.term
        }
        return "Speech recognition often mishears names; when a word or phrase sounds like one of these, write the term: "
            + entries.joined(separator: ", ") + "."
    }
}
