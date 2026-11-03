import Foundation
import Testing
@testable import DictateCore

/// v1.28 FR2-A: the possible-speech floor is never set by near-zeros. 19f69203 (2026-11-04 00:43): 2.4 s of the
/// headset's near-zeros (−88.9 dBFS, above the −100 dBFS digital-zero line) put the 10th-percentile floor at
/// ≈ −92.7 dBFS, so room noise at −46 dBFS was "6 dB over the floor" = possible speech and no chunk was emptied.
@Suite("V128PossibleSpeechFloor")
struct V128PossibleSpeechFloorTests {
    static func db(_ value: Double) -> Float { Float(pow(10, value / 20)) }
    /// 48 windows (2.4 s) of near-zeros + 400 room-noise windows at −46 ± 3.6 dB (p10 ≈ −50.6, p90 ≈ −41.4).
    static var reference: [Float] {
        let zeros = [Float](repeating: db(-88.9), count: 48)
        let noise = (0..<400).map { i -> Float in
            let z = (Double((i &* 7919) % 1000) / 1000 - 0.5) * 2 * 1.645     // uniform p5…p95 of ±1.645 sd
            return db(-46 + 3.6 * z)
        }
        return zeros + noise
    }
    static let steadyRoom = (0..<60).map { i in db(-46 + 0.3 * sin(Double(i))) }          // a chunk of room noise only
    static let softWord = steadyRoom + (0..<6).map { _ in db(-38) }                       // a soft word at −38 dBFS

    @Test func roomNoiseChunkIsSilentWhatTheNearZerosDoNotDecide() {
        let silent = EdgeSentenceGuard.isSilent(Self.steadyRoom, reference: Self.reference)
        let possible = CaptureEvidence.possibleSpeechWindows(Self.steadyRoom, reference: Self.reference).filter { $0 }.count
        let floor = 20 * log10(Double(CaptureEvidence.possibleSpeechFloor(reference: Self.reference)))
        print("FR2-A LITERAL floor=\(String(format: "%.1f", floor)) room_chunk silent=\(silent) possible_windows=\(possible)/\(Self.steadyRoom.count)")
        #expect(silent)
    }

    /// Floor clamps: no audible window → −60 dBFS; a quiet room at −75 dBFS (below the −70 line) → −60 dBFS.
    @Test func floorNeverBelowMinus60() {
        #expect(CaptureEvidence.possibleSpeechFloor(reference: []) == CaptureEvidence.possibleFloorMinimumRMS)
        #expect(CaptureEvidence.possibleSpeechFloor(reference: [Float](repeating: Self.db(-75), count: 50)) == CaptureEvidence.possibleFloorMinimumRMS)
        #expect(CaptureEvidence.possibleSpeechWindows([Self.db(-52)], reference: [Float](repeating: Self.db(-75), count: 50)) == [false])   // < −50
        #expect(CaptureEvidence.possibleSpeechWindows([Self.db(-48)], reference: [Float](repeating: Self.db(-75), count: 50)) == [true])    // ≥ −50, ≥ floor+6
    }

    /// Controls: a soft word at −38 dBFS (over the −40 always-speech line) keeps its chunk on both trees.
    @Test func softWordStillCounts() {
        let silent = EdgeSentenceGuard.isSilent(Self.softWord, reference: Self.reference)
        print("FR2-A CONTROL soft_word_-38 silent=\(silent)")
        #expect(!silent)
    }
}
