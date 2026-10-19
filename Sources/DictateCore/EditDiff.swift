import Foundation

/// v56 ST2: word-level diff between the text Dictate inserted and the same span as later observed.
public enum EditDiff {
    public static let maxPerDictation = 5

    private static let punctuationSet: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.formUnion(CharacterSet(charactersIn: "\"'`“”‘’«»„”"))
        return set
    }()

    /// Words in `observed` that REPLACED a different word at the same aligned position in `inserted`
    /// (word-level LCS/Levenshtein alignment on whitespace-split tokens, punctuation stripped from token
    /// ends). Only substitutions count (not pure insertions/deletions). A learned word is alphabetic
    /// (letters only, Unicode letters allowed), >= 3 characters, and differs from the inserted word
    /// other than by case. Deduplicated, in order of appearance, at most `maxPerDictation`.
    public static func replacedWords(inserted: String, observed: String) -> [String] {
        let insertedTokens = tokenize(inserted)
        let observedTokens = tokenize(observed)

        guard !insertedTokens.isEmpty && !observedTokens.isEmpty else {
            return []
        }

        let ops = align(inserted: insertedTokens, observed: observedTokens)

        var learned: [String] = []
        var seen = Set<String>()

        for op in ops {
            guard case let .substitution(insertedWord, observedWord) = op else {
                continue
            }
            guard isValidLearnedWord(observedWord, replaced: insertedWord) else {
                continue
            }
            if !seen.contains(observedWord) {
                seen.insert(observedWord)
                learned.append(observedWord)
                if learned.count >= maxPerDictation {
                    break
                }
            }
        }

        return learned
    }

    private static func isValidLearnedWord(_ word: String, replaced insertedWord: String) -> Bool {
        // >= 3 characters
        guard word.count >= 3 else { return false }
        // alphabetic (letters only, Unicode letters allowed)
        guard word.allSatisfy({ $0.isLetter }) else { return false }
        // differs from the inserted word other than by case
        guard word.lowercased() != insertedWord.lowercased() else { return false }
        return true
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let stripped = String(token).trimmingCharacters(in: punctuationSet)
            return stripped.isEmpty ? nil : stripped
        }
    }

    private enum Op {
        case match(inserted: String, observed: String)
        case substitution(inserted: String, observed: String)
        case deletion(inserted: String)
        case insertion(observed: String)
    }

    private enum Choice {
        case match
        case sub
        case del
        case ins
    }

    private static func align(inserted: [String], observed: [String]) -> [Op] {
        let m = inserted.count
        let n = observed.count

        // dp[i][j]: minimum cost to align inserted[0..<i] and observed[0..<j]
        // Costs:
        // match: 0.0
        // deletion: 1.0
        // insertion: 1.0
        // substitution: 1.4 (less than del+ins=2.0, prioritizing 1-to-1 substitution
        //                    over deletion+insertion, but greater than match=0.0)
        var dp = Array(repeating: Array(repeating: 0.0, count: n + 1), count: m + 1)
        var choice = Array(repeating: Array(repeating: Choice.match, count: n + 1), count: m + 1)

        for i in 1...m {
            dp[i][0] = Double(i) * 1.0
            choice[i][0] = .del
        }
        for j in 1...n {
            dp[0][j] = Double(j) * 1.0
            choice[0][j] = .ins
        }

        for i in 1...m {
            for j in 1...n {
                let insWord = inserted[i - 1]
                let obsWord = observed[j - 1]

                if insWord == obsWord {
                    dp[i][j] = dp[i - 1][j - 1]
                    choice[i][j] = .match
                } else {
                    let subCost = dp[i - 1][j - 1] + 1.4
                    let delCost = dp[i - 1][j] + 1.0
                    let insCost = dp[i][j - 1] + 1.0

                    let minCost = min(subCost, delCost, insCost)
                    dp[i][j] = minCost

                    if minCost == subCost {
                        choice[i][j] = .sub
                    } else if minCost == delCost {
                        choice[i][j] = .del
                    } else {
                        choice[i][j] = .ins
                    }
                }
            }
        }

        // Backtrack
        var i = m
        var j = n
        var ops: [Op] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && choice[i][j] == .match {
                ops.append(.match(inserted: inserted[i - 1], observed: observed[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0 && j > 0 && choice[i][j] == .sub {
                ops.append(.substitution(inserted: inserted[i - 1], observed: observed[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0 && (j == 0 || choice[i][j] == .del) {
                ops.append(.deletion(inserted: inserted[i - 1]))
                i -= 1
            } else {
                ops.append(.insertion(observed: observed[j - 1]))
                j -= 1
            }
        }

        return ops.reversed()
    }
}
