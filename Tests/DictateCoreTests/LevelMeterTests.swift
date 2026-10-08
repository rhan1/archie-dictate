import Foundation
import Testing
import DictateCore

private func rms(_ db: Float) -> Float { pow(10, db / 20) }

@Suite("LevelMeter")
struct LevelMeterTests {
    @Test func floorAndFullBeforeAnyGain() {
        var m = LevelMeter()
        #expect(m.level(rms: rms(-60), seconds: 0.064) == 0)                 // gated silence
        var loud = LevelMeter()
        #expect(loud.level(rms: rms(-10), seconds: 0.064) == 1)              // peak above full: no gain, capped
        #expect(abs(loud.level(rms: rms(-33), seconds: 0.064) - 0.5) < 0.01) // halfway in dB between −48 and −18
    }

    @Test func softHeadsetSpeechIsLiftedToMostOfTheRange() {
        var m = LevelMeter()
        // Speech peaking at −30 dBFS with ordinary syllables ~10 dB under the peak.
        _ = m.level(rms: rms(-30), seconds: 0.064)
        let syllable = m.level(rms: rms(-40), seconds: 0.064)
        #expect(syllable >= 0.7)                                             // looks like normal speech, not a whisper
        #expect(m.level(rms: rms(-30), seconds: 0.064) == 1)
    }

    @Test func gainIsCappedSoRoomNoiseStaysLow() {
        var m = LevelMeter()
        for _ in 0..<100 { _ = m.level(rms: rms(-52), seconds: 0.064) }      // only room noise for 6 s
        #expect(m.level(rms: rms(-52), seconds: 0.064) <= 0.5)
    }

    @Test func barsReachMostOfMaxHeightOnSpeechAndIdleInSilence() {
        var bars = PillBars()
        for _ in 0..<15 { bars.push(level: 0.85); bars.tick() }
        let top3 = bars.heights.sorted(by: >).prefix(3).reduce(0, +) / 3
        #expect(top3 / PillBars.peakHeight >= 0.7)
        #expect(bars.heights.filter { $0 > 2.5 }.count >= 7)
        for _ in 0..<60 { bars.push(level: 0); bars.tick() }
        #expect(bars.heights.allSatisfy { $0 < 2.2 })
    }
}
