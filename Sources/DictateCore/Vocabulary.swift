import Foundation

/// Canonical terms from the same hints file used for phonetic cleanup.
public enum Vocabulary {
    public static let maxPromptLength = 800

    public static func buildPrompt(
        fileURL: URL = AppPaths().vocabularyURL,
        bundledURL: URL? = Bundle.main.url(forResource: "vocab-hints.sample", withExtension: "txt")
    ) -> String {
        // Every canonical term belongs in the prompt; aliases never do.
        VocabHints.load(fileURL: fileURL, bundledURL: bundledURL).map(\.term).joined(separator: ", ")
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
