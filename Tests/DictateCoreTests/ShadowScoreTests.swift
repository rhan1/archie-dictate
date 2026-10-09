import Testing
import DictateCore

@Suite("ShadowScore")
struct ShadowScoreTests {
    @Test func namesLineReportsEngineRawAndFinalCountsOnly() {
        #expect(ShadowScore.namesLine(rawNames: 1, pastedNames: 4, path: "groq-chunked", openingExact: 1) ==
                "names_raw=1/4 names_pasted=4/4 path=groq-chunked opening_exact=1")
        #expect(ShadowScore.namesLine(rawNames: 3, pastedNames: 2, path: "apple", openingExact: 0) ==
                "names_raw=3/4 names_pasted=2/4 path=apple opening_exact=0")
        #expect(ShadowScore.namesLine(rawNames: 0, pastedNames: 0, path: "apple", openingExact: 0) ==
                "names_raw=0/4 names_pasted=0/4 path=apple opening_exact=0")
        #expect(ShadowScore.namesLine(rawNames: ShadowScore.nameCount(ShadowScore.script),
                                    pastedNames: ShadowScore.nameCount("Politrace Limpar"), path: "groq-chunked", openingExact: 1) ==
                "names_raw=4/4 names_pasted=2/4 path=groq-chunked opening_exact=1")
    }

    @Test func openingExact() {
        #expect(ShadowScore.openingExact("So for the Politrace launch, send the draft to the team.") == 1)
        #expect(ShadowScore.openingExact("Thank you for the Politrace launch, send the draft.") == 0)
        #expect(ShadowScore.openingExact("so for the Politrace launch") == 0)
        #expect(ShadowScore.openingExact(" So for the Politrace launch") == 0)
        #expect(ShadowScore.openingExact("") == 0)
    }

    @Test func scriptCounters() {
        let good = ShadowScore.expected
        let bad = "So, for the Politrace launch, send the draft to the team on Tuesday. Now, Wednesday, we need three things: the Limpar match counts, the DB99 query and other screenshots. Can you also check if TurnoutWatch is still running?"
        #expect(ShadowScore.openingExact(good) == 1)
        #expect(ShadowScore.phraseCount(good) == 3)
        #expect(ShadowScore.scriptExact(good) == 1)
        #expect(ShadowScore.openingExact(bad) == 0)
        #expect(ShadowScore.phraseCount(bad) == 1)
        #expect(ShadowScore.scriptExact(bad) == 0)
        #expect(ShadowScore.phraseCount(good.lowercased()) == 1)
        #expect(ShadowScore.scriptExact(good + " ") == 0)
        let line = ShadowScore.namesLine(rawNames: 4, pastedNames: 4, path: "groq-chunked", pastedText: good)
        #expect(line == "names_raw=4/4 names_pasted=4/4 path=groq-chunked opening_exact=1 phrases=3/3 script_exact=1")
        #expect(!line.contains("Politrace"))
        #expect(!line.contains("screenshots"))
    }

    @Test func shadowLineIncludesFinalPastedNameCount() {
        #expect(ShadowScore.line(appleNames: 1, pastedNames: 4, groqNames: 3, milliseconds: 287) ==
                "shadow=groq names_apple=1/4 names_pasted=4/4 names_groq=3/4 shadow_ms=287")
        #expect(ShadowScore.line(appleNames: 0, pastedNames: 0, groqNames: 0, milliseconds: 0) ==
                "shadow=groq names_apple=0/4 names_pasted=0/4 names_groq=0/4 shadow_ms=0")
    }

    @Test func identicalScript() {
        #expect(ShadowScore.overlap(ShadowScore.script) == 1)
        #expect(ShadowScore.overlap(ShadowScore.script.uppercased()) == 1)
    }

    @Test func unrelatedSentenceDoesNotTriggerShadow() {
        #expect(ShadowScore.overlap("A purple elephant crossed a frozen lake.") < 0.6)
        #expect(ShadowScore.overlap("") == 0)
    }

    @Test func overlapUsesMultisetAndIgnoresPunctuation() {
        let count = ShadowScore.script.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        #expect(ShadowScore.overlap("the") == 1.0 / Double(count))
        #expect(ShadowScore.overlap("the THE! the? the the the the") == 6.0 / Double(count))
        #expect(ShadowScore.overlap("DB99, Politrace!") == 2.0 / Double(count))
    }

    @Test func namesAreExactCaseSensitiveSubstrings() {
        #expect(ShadowScore.nameCount(ShadowScore.script) == 4)
        #expect(ShadowScore.nameCount("politrace limpar db99 turnoutwatch") == 0)
        #expect(ShadowScore.nameCount("Politrace Politrace, Limpar, DB99 query") == 3)
        #expect(ShadowScore.nameCount("preTurnoutWatchpost") == 1)
    }
}
