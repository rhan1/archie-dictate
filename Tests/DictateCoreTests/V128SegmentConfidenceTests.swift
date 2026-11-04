import Testing
@testable import DictateCore

/// v1.28 FR5-A: each drop rule and each never-drop guard of `SegmentConfidence`, on 50 ms windows.
@Suite("V128SegmentConfidence")
struct V128SegmentConfidenceTests {
    typealias Segment = EdgeSentenceGuard.Segment
    /// 2 s: the first second at −46 dBFS room noise, the second at −27 dBFS speech.
    let windows: [Float] = Array(repeating: 0.005, count: 20) + Array(repeating: 0.045, count: 20)
    func seg(_ start: Double, _ end: Double, p: Double? = nil, lp: Double? = nil, cr: Double? = nil) -> Segment {
        Segment(start: start, end: end, text: "Words here.", noSpeechProb: p, avgLogprob: lp, compressionRatio: cr)
    }

    @Test func rules() {
        let cases: [(String, Segment, Bool)] = [
            ("quiet p=0.82 lp=-1.3 (06:45 chunk 2)", seg(0, 0.95, p: 0.82, lp: -1.3), true),
            ("quiet p=0.65 lp=-0.4 (confident hallucination)", seg(0, 0.95, p: 0.65, lp: -0.4), true),
            ("quiet p=0.3 lp=-1.2", seg(0, 0.95, p: 0.3, lp: -1.2), true),
            ("quiet p=0.3 lp=-0.4", seg(0, 0.95, p: 0.3, lp: -0.4), false),
            ("quiet cr=2.6", seg(0, 0.95, p: 0.1, lp: -0.3, cr: 2.6), true),
            ("loud p=0.02 lp=-0.25 (real)", seg(1.0, 2.0, p: 0.02, lp: -0.25), false),
            ("loud p=0.3 lp=-1.4 (quiet real control)", seg(1.0, 2.0, p: 0.3, lp: -1.4), false),
            ("loud p=0.3 cr=2.6 (never drop: loud and p<0.6)", seg(1.0, 2.0, p: 0.3, lp: -0.3, cr: 2.6), false),
            ("loud p=0.7 lp=-0.3 (loud and confident)", seg(1.0, 2.0, p: 0.7, lp: -0.3), false),
            ("loud p=0.7 lp=-1.3", seg(1.0, 2.0, p: 0.7, lp: -1.3), true),
            ("no confidences, quiet", seg(0, 0.95), false),
        ]
        var literal: [String] = []
        for (name, segment, expected) in cases {
            let dropped = SegmentConfidence.drops(segment, windows: windows)
            literal.append("\(name)=\(dropped ? "drop" : "keep")")
            #expect(dropped == expected, "\(name)")
        }
        print("FR5-A LITERAL rules \(literal.joined(separator: "; "))")
    }

    @Test func filterRebuildsTextAndSkipsMismatch() {
        let segments = [Segment(start: 0, end: 0.95, text: " Let's see.", noSpeechProb: 0.82, avgLogprob: -1.3),
                        Segment(start: 1.0, end: 2.0, text: " Cold start one.", noSpeechProb: 0.02, avgLogprob: -0.25)]
        let kept = SegmentConfidence.filter(text: "Let's see. Cold start one.", segments: segments, windows: windows)
        #expect(kept.text == "Cold start one." && kept.dropped == 1 && kept.segments?.count == 1)
        let mismatch = SegmentConfidence.filter(text: "Something else.", segments: segments, windows: windows)
        #expect(mismatch.text == "Something else." && mismatch.dropped == 0)
        let none = SegmentConfidence.filter(text: "Plain.", segments: nil, windows: windows)
        #expect(none.text == "Plain." && none.dropped == 0)
        let trace = SegmentConfidence.describe(segments, windows: windows)
        print("FR5-A LITERAL trace segments=\(trace) | none=\(SegmentConfidence.describe(nil, windows: windows))")
        #expect(trace == "[0.00-0.95 p=0.82 lp=-1.30 cr=- \"Let's see.\" dropped, 1.00-2.00 p=0.02 lp=-0.25 cr=- \"Cold start one.\"]")
    }
}
