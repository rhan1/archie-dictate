import Foundation
import Testing
import DictateCore

@Suite("Vocabulary")
struct VocabTests {
    @Test func everyCanonicalTermFeedsPromptButAliasesDoNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hints.txt")
        try "# comment\nKubernetes <- cube and eighties\nPostgreSQL <- post gress\nAcme Corp\n".write(
            to: file, atomically: true, encoding: .utf8)
        #expect(Vocabulary.buildPrompt(fileURL: file, bundledURL: nil) == "Kubernetes, PostgreSQL, Acme Corp")
    }

    @Test func missingFileHasNoSeed() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(Vocabulary.buildPrompt(fileURL: missing, bundledURL: nil) == "")
    }

    @Test func allTermsRemainEvenBeyondOldPromptCap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hints.txt")
        let terms = (0..<200).map { "GenericTerm\($0)" }
        try terms.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let prompt = Vocabulary.buildPrompt(fileURL: file, bundledURL: nil)
        #expect(prompt.count > Vocabulary.maxPromptLength)
        #expect(prompt == terms.joined(separator: ", "))
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

    @Test func capBoundaryAndOversizedTerm() {
        #expect(Vocabulary.join(["Alpha", "Beta"], cap: 11) == "Alpha, Beta")
        #expect(Vocabulary.join(["Alpha", "Beta"], cap: 10) == "Alpha")
        #expect(Vocabulary.join(["Oversized", "A"], cap: 3) == "")
        #expect(Vocabulary.join(["A"], cap: 0) == "")
        #expect(Vocabulary.join([], cap: 800) == "")
    }
}
