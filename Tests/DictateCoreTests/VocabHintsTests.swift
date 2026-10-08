import Foundation
import Testing
import DictateCore

@Suite("VocabHints")
struct VocabHintsTests {
    @Test func parsesCommentsBareTermsAndWhitespaceInOrder() {
        let hints = VocabHints.parse("""
          # names

          Kubernetes  <-  cube and eighties , kuber netties, ,
        \t
          PostgreSQL <- postgres q l,  post gress
        # ignored <- alias
          Acme Corp
         <- missing term
        EmptyAliases <- , ,
        """)
        #expect(hints.map(\.term) == ["Kubernetes", "PostgreSQL", "Acme Corp", "EmptyAliases"])
        #expect(hints.map(\.aliases) == [["cube and eighties", "kuber netties"], ["postgres q l", "post gress"], [], []])
    }

    @Test func onlyAliasedTermsAppearInPhoneticSentence() {
        let hints = VocabHints.parse("Kubernetes <- cube and eighties, kuber netties\nAcme Corp\nPostgreSQL <- postgres q l, post gress")
        #expect(VocabHints.promptSentence(hints) ==
                #"Speech recognition often mishears names; when a word or phrase sounds like one of these, write the term: "cube and eighties" / "kuber netties" → Kubernetes, "postgres q l" / "post gress" → PostgreSQL."#)
    }

    @Test func emptyOrBareHintsProduceNoPhoneticSentence() {
        #expect(VocabHints.promptSentence(VocabHints.parse("")) == "")
        #expect(VocabHints.promptSentence(VocabHints.parse("# comment\n \nAcme Corp")) == "")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(TranscriptCleaner.loadHintsSentence(fileURL: missing, bundledURL: nil) == "")
    }

    @Test func editableFileOverridesBundleAndReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editable = directory.appendingPathComponent("editable.txt")
        let bundled = directory.appendingPathComponent("bundled.txt")
        try "PostgreSQL <- post gress\nAcme Corp".write(to: bundled, atomically: true, encoding: .utf8)
        #expect(TranscriptCleaner.loadHintsSentence(fileURL: editable, bundledURL: bundled) ==
                #"Speech recognition often mishears names; when a word or phrase sounds like one of these, write the term: "post gress" → PostgreSQL."#)
        #expect(Vocabulary.buildPrompt(fileURL: editable, bundledURL: bundled) == "PostgreSQL, Acme Corp")
        try "draft <- drive, draught\nKubernetes".write(to: editable, atomically: true, encoding: .utf8)
        #expect(TranscriptCleaner.loadHintsSentence(fileURL: editable, bundledURL: bundled) ==
                #"Speech recognition often mishears names; when a word or phrase sounds like one of these, write the term: "drive" / "draught" → draft."#)
        #expect(Vocabulary.buildPrompt(fileURL: editable, bundledURL: bundled) == "draft, Kubernetes")
        try "".write(to: editable, atomically: true, encoding: .utf8)
        #expect(TranscriptCleaner.loadHintsSentence(fileURL: editable, bundledURL: bundled) == "")
        #expect(Vocabulary.buildPrompt(fileURL: editable, bundledURL: bundled) == "")
    }

    @Test func existingUnreadableFileDoesNotFallBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editable = directory.appendingPathComponent("editable.txt")
        let bundled = directory.appendingPathComponent("bundled.txt")
        try Data([0xff, 0xfe, 0xff]).write(to: editable)
        try "Acme Corp".write(to: bundled, atomically: true, encoding: .utf8)
        #expect(Vocabulary.buildPrompt(fileURL: editable, bundledURL: bundled) == "")
    }
}
