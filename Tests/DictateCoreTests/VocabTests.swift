import Foundation
import Testing
import DictateCore

@Suite("Vocabulary")
struct VocabTests {
    @Test func extractsExactTermsInAppearanceOrder() {
        let fixture = """
        ---
        title: **Ignored** `Hidden`
        ---
        Ordinary prose with Uppercase words is ignored.
        | **Limpar** | **TurnoutWatch** |
        Use `DB99` here.
        - Ask Politrace about GrantWatch
        """
        #expect(Vocabulary.extractTerms(markdown: fixture) ==
                ["Limpar", "TurnoutWatch", "DB99", "Ask", "Politrace", "GrantWatch"])
    }
    @Test func capKeepsWholeTerms() {
        let terms = (0..<200).map { "LongVocabularyTerm\($0)" }
        let prompt = Vocabulary.join(terms)
        #expect(prompt.count <= 800)
        #expect(!prompt.hasSuffix(", "))
        let included = prompt.components(separatedBy: ", ")
        #expect(included == Array(terms.prefix(included.count)))
        #expect((prompt + ", " + terms[included.count]).count > 800)
    }
    @Test func missingFileFallsBackToSeed() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(Vocabulary.filePrompt(fileURL: url) == "")
        #expect(Vocabulary.buildPrompt(fileURL: url) == Vocabulary.seed.joined(separator: ", "))
    }
    @Test func fileTermDeduplicatesSeed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.md")
        try "**Limpar** `CustomTerm` **Limpar**".write(to: url, atomically: true, encoding: .utf8)
        #expect(Vocabulary.filePrompt(fileURL: url) == "Limpar, CustomTerm")
        #expect(Vocabulary.buildPrompt(fileURL: url) ==
                "Limpar, CustomTerm, Raza, Politrace, GrantWatch, TurnoutWatch, DB99, Archie, Jarvis, Codex, agy, Warp, Claude, Fable, Opus, Sonnet")
    }
    @Test func allListMarkersStopwordsAndPunctuation() {
        let markdown = """
        - The (Alpha2), And [Beta].
          * Read Gamma-3 With Delta
        + See Epsilon
        12. Add Zeta To Eta
        Plain Theta
        """
        #expect(Vocabulary.extractTerms(markdown: markdown) ==
                ["Alpha2", "Beta", "Gamma-3", "Delta", "Epsilon", "Zeta", "Eta"])
    }
    @Test func spansAreTrimmedAndCaseSensitive() {
        #expect(Vocabulary.extractTerms(markdown: "** Limpar ** then `limpar` then **Limpar** and ` DB99 `") ==
                ["Limpar", "limpar", "DB99"])
    }
    @Test func listAndSpanOrderIsShared() {
        #expect(Vocabulary.extractTerms(markdown: "- Alpha **Beta** `Gamma` Delta") ==
                ["Alpha", "Beta", "Gamma", "Delta"])
    }
    @Test func capBoundaryAndOversizedTerm() {
        #expect(Vocabulary.join(["Alpha", "Beta"], cap: 11) == "Alpha, Beta")
        #expect(Vocabulary.join(["Alpha", "Beta"], cap: 10) == "Alpha")
        #expect(Vocabulary.join(["Oversized", "A"], cap: 3) == "")
        #expect(Vocabulary.join(["A"], cap: 0) == "")
        #expect(Vocabulary.join([], cap: 800) == "")
    }
}
