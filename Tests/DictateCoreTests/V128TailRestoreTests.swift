import Testing
@testable import DictateCore

/// v1.28 FR3-C: the post-check (no model) and the prompt rule.
@Suite("V128TailRestore")
struct V128TailRestoreTests {
    @Test func razasPairIsRestored() {
        let r = TranscriptCleaner.restoreShortTail(raw: "Send the invoice to Limpar today. Yes.", cleaned: "Send the invoice to Limpar today.")
        print("FR3-C LITERAL post_check text=\"\(r.text)\" restored=\(r.restored)")
        #expect(r.text == "Send the invoice to Limpar today. Yes." && r.restored)
    }

    @Test func otherAnswersAndControls() {
        for answer in ["No.", "Okay.", "Thanks.", "Done."] {
            #expect(TranscriptCleaner.restoreShortTail(raw: "Ship the build tonight. \(answer)", cleaned: "Ship the build tonight.").text
                    == "Ship the build tonight. \(answer)")
        }
        // Kept when the cleaner kept it; corrections, fillers and artifacts are never put back; one sentence alone is not.
        #expect(!TranscriptCleaner.restoreShortTail(raw: "Send it today. Yes.", cleaned: "Send it today. Yes.").restored)
        #expect(!TranscriptCleaner.restoreShortTail(raw: "Send the draft on Tuesday. No, Wednesday.", cleaned: "Send the draft on Wednesday.").restored)
        #expect(!TranscriptCleaner.restoreShortTail(raw: "Send the draft today. Um.", cleaned: "Send the draft today.").restored)
        #expect(!TranscriptCleaner.restoreShortTail(raw: "Send the draft today. Thank you.", cleaned: "Send the draft today.").restored)
        #expect(!TranscriptCleaner.restoreShortTail(raw: "Send the draft today and then call Maria.", cleaned: "Send the draft today, then call Maria.").restored)
        #expect(!TranscriptCleaner.restoreShortTail(raw: "Yes.", cleaned: "").restored)
    }

    @Test func promptKeepsSentenceFinalAnswers() {
        let prompts = [TranscriptCleaner.instructions, TranscriptCleaner.midInstructions]
        print("FR3-C LITERAL prompt_rule=\(prompts.map { $0.contains("Yes.") })")
        #expect(prompts.allSatisfy { $0.contains("\"Yes.\"") && $0.contains("Done.") })   // mid prompt: compact (≤ 400-token budget)
    }
}
