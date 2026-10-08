import Testing
import DictateCore

@Suite("ShadowScore")
struct ShadowScoreTests {
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
