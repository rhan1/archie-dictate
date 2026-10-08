import Foundation
import Testing
import DictateCore

@Suite("VocabHints")
struct VocabHintsTests {
    @Test func parsesCommentsBlankLinesAndWhitespaceInOrder() {
        let hints = VocabHints.parse("""
          # names

          DB99  <-  he beat 99 , dee bee ninety-nine, ,
        \t
          Limpar <- limp r,  limp are
        # ignored <- alias
        missing delimiter
         <- missing term
        empty <- , ,
        """)
        #expect(hints.count == 2)
        #expect(hints.map(\.term) == ["DB99", "Limpar"])
        #expect(hints.map(\.aliases) == [["he beat 99", "dee bee ninety-nine"], ["limp r", "limp are"]])
    }

    @Test func twoEntryPromptIsExact() {
        let hints = VocabHints.parse("DB99 <- he beat 99, dee bee ninety-nine\nLimpar <- limp r, limp are")
        #expect(VocabHints.promptSentence(hints) ==
                #"Speech recognition often mishears names; when a word or phrase sounds like one of these, write the term: "he beat 99" / "dee bee ninety-nine" → DB99, "limp r" / "limp are" → Limpar."#)
    }

    @Test func emptyOrMissingHintsProduceNoSentence() {
        #expect(VocabHints.promptSentence(VocabHints.parse("")) == "")
        #expect(VocabHints.promptSentence(VocabHints.parse("# comment\n \ninvalid")) == "")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(TranscriptCleaner.loadHintsSentence(fileURL: missing, bundledURL: nil) == "")
    }

    @Test func editableFileOverridesBundleAndReloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editable = directory.appendingPathComponent("editable.txt")
        let bundled = directory.appendingPathComponent("bundled.txt")
        try "Limpar <- limp r".write(to: bundled, atomically: true, encoding: .utf8)
        #expect(TranscriptCleaner.loadHintsSentence(fileURL: editable, bundledURL: bundled) ==
                #"Speech recognition often mishears names; when a word or phrase sounds like one of these, write the term: "limp r" → Limpar."#)
        try "draft <- drive, draught".write(to: editable, atomically: true, encoding: .utf8)
        #expect(TranscriptCleaner.loadHintsSentence(fileURL: editable, bundledURL: bundled) ==
                #"Speech recognition often mishears names; when a word or phrase sounds like one of these, write the term: "drive" / "draught" → draft."#)
        try "".write(to: editable, atomically: true, encoding: .utf8)
        #expect(TranscriptCleaner.loadHintsSentence(fileURL: editable, bundledURL: bundled) == "")
    }
}
