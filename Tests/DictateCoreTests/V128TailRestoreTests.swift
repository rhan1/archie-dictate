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

    /// v1.28 FR4-B (FR3 stop-rule review): the restore is only for a closed answer phrase. RED on 0051609: a filler
    /// ("You know.") is put back, and a correction's tail ("No, Wednesday.") is re-appended after the cleaner applied it.
    @Test func onlyClosedAnswersAreRestored() {
        let filler = TranscriptCleaner.restoreShortTail(raw: "Send the draft today. You know.", cleaned: "Send the draft today.")
        let correction = TranscriptCleaner.restoreShortTail(raw: "Send it Tuesday. Then call Maria. No, Wednesday.",
                                                            cleaned: "Send it Wednesday. Then call Maria.")
        let cue = TranscriptCleaner.restoreShortTail(raw: "Send it Tuesday. Sorry, make that Wednesday. Okay.",
                                                     cleaned: "Send it Wednesday.")
        let yes = TranscriptCleaner.restoreShortTail(raw: "Send the invoice to Limpar today. Yes.", cleaned: "Send the invoice to Limpar today.")
        let goAhead = TranscriptCleaner.restoreShortTail(raw: "Deploy the build tonight. Go ahead.", cleaned: "Deploy the build tonight.")
        print("FR4-B LITERAL you_know restored=\(filler.restored) text=\"\(filler.text)\" | correction restored=\(correction.restored) text=\"\(correction.text)\" | cue restored=\(cue.restored) | yes restored=\(yes.restored) text=\"\(yes.text)\" | go_ahead restored=\(goAhead.restored)")
        #expect(!filler.restored && filler.text == "Send the draft today.")
        #expect(!correction.restored && correction.text == "Send it Wednesday. Then call Maria.")
        #expect(!cue.restored && cue.text == "Send it Wednesday.")
        #expect(yes.restored && yes.text == "Send the invoice to Limpar today. Yes.")
        #expect(goAhead.restored && goAhead.text == "Deploy the build tonight. Go ahead.")
        for filler in ["I mean.", "Uh-huh.", "Um.", "You know what."] {
            #expect(!TranscriptCleaner.restoreShortTail(raw: "Send the draft today. \(filler)", cleaned: "Send the draft today.").restored)
        }
    }

    @Test func promptKeepsSentenceFinalAnswers() {
        let prompts = [TranscriptCleaner.instructions, TranscriptCleaner.midInstructions]
        print("FR3-C LITERAL prompt_rule=\(prompts.map { $0.contains("Yes.") })")
        #expect(prompts.allSatisfy { $0.contains("\"Yes.\"") && $0.contains("Done.") })   // mid prompt: compact (≤ 400-token budget)
    }
}
