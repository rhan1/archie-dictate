import Foundation

/// Text stays in memory; only these counts may be emitted by shadow QA.
public enum ShadowScore {
    public static let script = "Um, so for the Politrace launch, send the draft to the team on Tuesday, no, Wednesday. We need, like, three things: the Limpar match counts, the DB99 query, and, uh, the screenshots. Can you also check if TurnoutWatch is still running?"
    public static let expected = "So for the Politrace launch, send the draft to the team on Wednesday. We need three things: the Limpar match counts, the DB99 query, and the screenshots. Can you also check if TurnoutWatch is still running?"
    public static let phrases = ["the Limpar match counts", "the screenshots", "on Wednesday"]
    public static let names = ["Politrace", "Limpar", "DB99", "TurnoutWatch"]

    public static func line(appleNames: Int, pastedNames: Int, groqNames: Int, milliseconds: Int) -> String {
        "shadow=groq names_apple=\(appleNames)/4 names_pasted=\(pastedNames)/4 names_groq=\(groqNames)/4 shadow_ms=\(milliseconds)"
    }

    /// The selected engine's raw text and the final paste; no shadow request.
    public static func namesLine(rawNames: Int, pastedNames: Int, path: String, openingExact: Int) -> String {
        "names_raw=\(rawNames)/4 names_pasted=\(pastedNames)/4 path=\(path) opening_exact=\(openingExact)"
    }

    public static func openingExact(_ pastedText: String) -> Int {
        pastedText.hasPrefix("So for the Politrace launch") ? 1 : 0
    }

    public static func phraseCount(_ pastedText: String) -> Int {
        phrases.filter { pastedText.contains($0) }.count
    }
    public static func scriptExact(_ pastedText: String) -> Int { pastedText == expected ? 1 : 0 }

    public static func namesLine(rawNames: Int, pastedNames: Int, path: String, pastedText: String) -> String {
        namesLine(rawNames: rawNames, pastedNames: pastedNames, path: path, openingExact: openingExact(pastedText)) +
            " phrases=\(phraseCount(pastedText))/3 script_exact=\(scriptExact(pastedText))"
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    public static func overlap(_ transcript: String) -> Double {
        var counts: [String: Int] = [:]
        for token in tokens(transcript) { counts[token, default: 0] += 1 }
        let expected = tokens(script)
        var hits = 0
        for token in expected where counts[token, default: 0] > 0 {
            counts[token, default: 0] -= 1
            hits += 1
        }
        return Double(hits) / Double(expected.count)
    }

    public static func nameCount(_ transcript: String) -> Int {
        names.filter { transcript.contains($0) }.count
    }
}
