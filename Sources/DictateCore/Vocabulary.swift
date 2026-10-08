import Foundation

public enum Vocabulary {
    public static let seed: [String] = ["Raza", "Limpar", "Politrace", "GrantWatch", "TurnoutWatch", "DB99", "Archie", "Jarvis", "Codex", "agy", "Warp", "Claude", "Fable", "Opus", "Sonnet"]
    public static let maxPromptLength = 800
    private static let stopwords: Set<String> = ["A", "An", "The", "And", "Or", "But", "If", "I", "It", "In", "On", "Of", "To", "For", "With", "When", "Do", "Not", "Add", "See", "Read"]

    public static func extractTerms(markdown: String) -> [String] {
        var lines = markdown.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .newlines) == "---",
           let end = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .newlines) == "---"
           }) {
            lines.removeFirst(end + 1)
        }
        let source = lines.joined(separator: "\n")
        let nsSource = source as NSString
        var matches: [(offset: Int, term: String)] = []
        let spans = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|`([^`]+)`"#,
                                             options: [.dotMatchesLineSeparators])
        for match in spans.matches(in: source, range: NSRange(location: 0, length: nsSource.length)) {
            let range = match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2)
            let term = nsSource.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty { matches.append((match.range.location, term)) }
        }
        let listPrefix = try! NSRegularExpression(pattern: #"^(?:[-*+] |[0-9]+\. )"#)
        let words = try! NSRegularExpression(pattern: #"\S+"#)
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        var offset = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if listPrefix.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil {
                let nsLine = line as NSString
                for word in words.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                    let term = nsLine.substring(with: word.range).trimmingCharacters(in: punctuation)
                    if let first = term.utf8.first, (65...90).contains(first), !stopwords.contains(term) {
                        matches.append((offset + word.range.location, term))
                    }
                }
            }
            offset += (line as NSString).length + 1
        }
        // For identical offsets, preserve insertion order (span before its list word).
        let ordered = matches.enumerated().sorted {
            $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset
        }
        var seen = Set<String>()
        return ordered.compactMap { seen.insert($0.element.term).inserted ? $0.element.term : nil }
    }

    public static func filePrompt(fileURL: URL) -> String {
        guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else { return "" }
        return join(extractTerms(markdown: markdown))
    }

    public static func buildPrompt(fileURL: URL) -> String {
        let terms = (try? String(contentsOf: fileURL, encoding: .utf8)).map(extractTerms(markdown:)) ?? []
        var seen = Set<String>()
        return join((terms + seed).filter { seen.insert($0).inserted })
    }

    public static func join(_ terms: [String], cap: Int = maxPromptLength) -> String {
        var result = ""
        for term in terms where !term.isEmpty {
            let addition = (result.isEmpty ? "" : ", ") + term
            guard result.count + addition.count <= cap else { break }
            result += addition
        }
        return result
    }
}
