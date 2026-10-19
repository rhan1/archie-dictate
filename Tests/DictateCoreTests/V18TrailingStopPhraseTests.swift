import Testing
@testable import DictateCore

/// v18 (Archie v55 X1 b): the trailing stop phrase is recognised only as the LAST, standalone sentence.
@Suite("V18TrailingStopPhraseTests")
struct V18TrailingStopPhraseTests {
    private let stripped: [(heard: String, kept: String)] = [
        ("Please send the report. Stop dictation.", "Please send the report."),
        ("stop dictation", ""),
        ("Stop dictation!", ""),
        ("STOP DICTATION.", ""),
        ("Thanks. Archie, stop.", "Thanks."),
        ("Okay that's it. End dictation", "Okay that's it."),
        ("Line one.\nstop dictation", "Line one."),
        ("Is that right? Archie stop.", "Is that right?"),
        ("Done\u{2026} stop dictation.", "Done\u{2026}"),
        ("  Archie stop  ", ""),
    ]

    private let untouched = [
        "I told him to stop dictation yesterday.",
        "He said stop dictation.",
        "He said, stop dictation.",
        "Please do not stop dictation.",
        "Stop dictation now.",
        "Don't stop dictation",
        "It is a nonstop dictation.",
        "A backstop dictation.",
        "We stop dictations.",
        "Please stop. Dictation.",
        "Stop dictation. Then send the email.",
        "archie stopped",
        "tell Archie stop talking",
        "",
        "   ",
        "End of dictation.",
    ]

    @Test func standaloneTrailingPhraseIsRemoved() {
        var bad: [String] = []
        for (heard, kept) in stripped {
            let r = TrailingStopPhrase.strip(heard)
            if !(r.matched && r.text == kept) { bad.append("[\(heard.count) chars] matched=\(r.matched) kept=\(r.text.count)") }
        }
        print("X1b STRIP cases=\(stripped.count) wrong=\(bad.count)")
        #expect(bad.isEmpty, "\(bad)")
    }

    @Test func wordsThatMerelyMentionThePhraseAreNeverStripped() {
        var bad: [String] = []
        for heard in untouched {
            let r = TrailingStopPhrase.strip(heard)
            if r.matched || r.text != heard { bad.append("[\(heard.count) chars] matched=\(r.matched)") }
        }
        print("X1b CONTROL untouched cases=\(untouched.count) stripped=\(bad.count)")
        #expect(bad.isEmpty, "\(bad)")
    }

    @Test func liveStopFiresOnTheSameRuleAndOnNothingElse() {
        let yes = stripped.map(\.heard).filter { TrailingStopPhrase.endsDictation($0) }.count
        let no = untouched.filter { TrailingStopPhrase.endsDictation($0) }.count
        print("X1b LIVE ends=\(yes)/\(stripped.count) false_ends=\(no)/\(untouched.count)")
        #expect(yes == stripped.count)
        #expect(no == 0)
    }
}
