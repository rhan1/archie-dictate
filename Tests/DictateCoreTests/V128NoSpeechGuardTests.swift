import Foundation
import Testing
@testable import DictateCore

/// v1.28 FR2-B: the decision rule on its own (the controller replay is V128Silence).
@Suite("V128NoSpeechGuard")
struct V128NoSpeechGuardTests {
    static let pasted = "dives by T Dictate dives by T T T Dictate dives by T T T Thank you.the floor. Thank you."

    @Test func rejectionThatWouldPasteRaw() {
        #expect(NoSpeechGuard.garbageRejected(cleanupLabel: "rejected:ratio", fallbackReason: nil))
        #expect(NoSpeechGuard.garbageRejected(cleanupLabel: "rejected:ratio", fallbackReason: "mid_rejected_ratio"))
        #expect(NoSpeechGuard.garbageRejected(cleanupLabel: "skipped:network", fallbackReason: "mid_rejected_ratio"))
        // Not a rejection, or not a raw paste: unchanged.
        #expect(!NoSpeechGuard.garbageRejected(cleanupLabel: "skipped:network", fallbackReason: nil))
        #expect(!NoSpeechGuard.garbageRejected(cleanupLabel: "ok", fallbackReason: "mid_rejected_ratio"))
        #expect(!NoSpeechGuard.garbageRejected(cleanupLabel: "fallback_local", fallbackReason: "mid_rejected_ratio"))
        #expect(!NoSpeechGuard.garbageRejected(cleanupLabel: "skipped:short", fallbackReason: "mid_rejected_ratio"))
        #expect(!NoSpeechGuard.garbageRejected(cleanupLabel: nil, fallbackReason: "mid_rejected_ratio"))
    }

    @Test func artifactRatioOfRazasPaste() {
        let ratio = NoSpeechGuard.artifactRatio(Self.pasted, vocabulary: "Politrace, Archie, Dictate")
        print("FR2-B LITERAL artifact_ratio=\(String(format: "%.2f", ratio)) text=19f69203_paste")
        #expect(ratio >= NoSpeechGuard.artifactShare)
        #expect(NoSpeechGuard.artifactRatio("I think we should send the report to Archie today", vocabulary: "Politrace, Archie") < 0.5)
        #expect(NoSpeechGuard.artifactRatio("Thank you.", vocabulary: "") == 1)
    }

    @Test func evidenceBranches() {
        let room = (0..<(24_000 * 4)).map { i in Float(0.005) * Float(sin(Double(i) * 0.37)) }        // ≈ −49 dBFS
        let speech = (0..<(24_000 * 4)).map { i in Float(0.25) * Float(sin(Double(i) * 2 * .pi * 220 / 24_000)) }
        let weak = NoSpeechGuard.evidence(samples: room, text: "send the report today please now", vocabulary: "")
        let strong = NoSpeechGuard.evidence(samples: speech, text: "please send the report to archie today", vocabulary: "Archie")
        print("FR2-B LITERAL weak \(weak.note) | strong \(strong.note)")
        #expect(weak.weak)
        #expect(!strong.weak)
    }
}
