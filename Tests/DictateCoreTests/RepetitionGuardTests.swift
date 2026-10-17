import Foundation
import Testing
import DictateCore

/// M2: the 2026-10-17 00:43 paste. Raza said only "testing" (4.2 s, two chunks); Groq whisper
/// returned this loop, cleanup failed on the network, and the raw text was pasted.
@Suite("RepetitionGuard (M2)")
struct RepetitionGuardTests {
    static let loopChunk = "Lime, Ngo, Hori, Turs, Gart, Gartburg, Lime, " + Array(repeating: "Ngo,", count: 35).joined(separator: " ") + " Ngo."
    static let testingChunk = "Testing, testing, testing, testing, testing, testing testing, testing, testing Testing, testing."
    static let incident = loopChunk + " " + testingChunk

    /// The text that would be pasted for the incident's two chunks (2.1 s of audio each).
    static func pasted() -> (text: String, loops: Int) {
        let parts = [loopChunk, testingChunk].map { RepetitionGuard.guardChunk($0, audioSeconds: 2.1) }
        let joined = parts.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        let collapsed = RepetitionGuard.collapseRuns(joined)
        return (collapsed.text, parts.map(\.loops).reduce(collapsed.loops, +))
    }

    static func longestRun(_ text: String) -> Int {
        let tokens = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        var best = 0, run = 0, last = ""
        for t in tokens { run = t == last ? run + 1 : 1; last = t; best = max(best, run) }
        return best
    }

    @Test func incidentLoopIsNotPastedRaw() {
        let out = Self.pasted()
        #expect(out.text != Self.incident)
        #expect(Self.longestRun(out.text) <= 3)
        #expect(!out.text.contains("Gartburg"))
        #expect(out.text.lowercased().contains("testing"))     // the real word survives
        #expect(out.loops > 0)
    }

    @Test func collapsesFourOrMoreIdenticalTokens() {
        #expect(RepetitionGuard.collapseRuns("Ngo, Ngo, Ngo, Ngo, then we go.").text == "Ngo, then we go.")
        #expect(RepetitionGuard.collapseRuns("Testing, testing, testing, testing.").text == "Testing.")
    }

    @Test func legitimateRepeatsAndLongDictationsAreUnchanged() {
        let normal = "No, no, no, I said the report goes out on Tuesday, not Monday."
        #expect(RepetitionGuard.collapseRuns(normal) == .init(text: normal, loops: 0))
        #expect(RepetitionGuard.guardChunk(normal, audioSeconds: 4.0) == .init(text: normal, loops: 0))
        let long = """
        Okay so for the Michigan matching we need to pull the budget organizations first, then run them against Limpar, \
        and anything under the threshold goes into the review tab. Very, very important that we keep the original names \
        as they appear in the appropriations bill, because the coworker checks them against the source PDF page by page.
        """
        #expect(RepetitionGuard.collapseRuns(long) == .init(text: long, loops: 0))
        #expect(RepetitionGuard.guardChunk(long, audioSeconds: 22.0) == .init(text: long, loops: 0))
    }

    @Test func loopChunkByRateOrDominantTokenIsDropped() {
        // 316 chars in ~2 s, 80 % one token: dropped whole.
        #expect(RepetitionGuard.guardChunk(Self.loopChunk, audioSeconds: 2.1).text == "")
        // A pure repetition of one real word keeps that word once.
        #expect(RepetitionGuard.guardChunk(Self.testingChunk, audioSeconds: 2.1).text == "Testing.")
        // Under 8 tokens the dominant-token rule does not apply.
        #expect(RepetitionGuard.guardChunk("Yes yes yes.", audioSeconds: 1.0).text == "Yes yes yes.")
    }

    @Test func fastButVariedChunkIsKept() {
        // 30 chars/s but no repetition: the rate rule alone never deletes real words.
        let fast = "Quarterly figures beat expectations across every region."
        #expect(RepetitionGuard.guardChunk(fast, audioSeconds: 1.8) == .init(text: fast, loops: 0))
    }
}
