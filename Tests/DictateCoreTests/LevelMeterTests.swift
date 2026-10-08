import Foundation
import Testing
import DictateCore

@Suite("WisprLevel")
struct LevelMeterTests {
    @Test func floorOnlyAdaptsDownAndIsBounded() {
        var meter = WisprLevel()
        #expect(meter.floorDB == 0)
        #expect(meter.level(db: -30) == 0)
        #expect(meter.floorDB == -30)
        _ = meter.level(db: -10)
        #expect(meter.floorDB == -30)
        _ = meter.level(db: -80)
        #expect(meter.floorDB == -60)
        meter.clearBatch()
        _ = meter.level(db: -40)
        #expect(meter.floorDB == -60)
    }

    @Test func normalizationUsesTwentyDbSpanAndClamps() {
        var meter = WisprLevel()
        _ = meter.level(db: -60)
        #expect(meter.level(db: -70) == 0)
        #expect(meter.level(db: -60) == 0)
        #expect(meter.level(db: -55) == 0.25)
        #expect(meter.level(db: -50) == 0.5)
        #expect(meter.level(db: -40) == 1)
        #expect(meter.level(db: 0) == 1)
    }

    @Test func chunksUseExactRmsDbFormula() {
        #expect(WisprLevel.db(samples: [0, 0]) == -200)
        #expect(abs(WisprLevel.db(samples: [0.5, -0.5]) - (-6.020599911542446)) < 1e-9)
    }

    @Test func batchMeanAt150MsAndEmptyWindowHoldsTarget() {
        var meter = WisprLevel(), bars = PillBars()
        meter.append(db: -60, at: 0) // level 0
        meter.append(db: -40, at: 0.040) // level 1
        meter.append(db: -50, at: 0.080) // level .5
        #expect(meter.batch(at: 0.149) == nil)
        let mean = meter.batch(at: 0.150)
        #expect(mean == 0.5)
        if let mean { bars.push(level: mean) }
        bars.tick()
        #expect(bars.smoothed == 0.07)
        #expect(meter.batch(at: 0.300) == nil)
        bars.tick()
        #expect(bars.smoothed == 0.13) // no event means target remains .5
        meter.append(db: -60, at: 0.320)
        #expect(meter.batch(at: 0.449) == nil)
        #expect(meter.batch(at: 0.450) == 0)
    }
}

@Suite("PillBars")
struct PillBarsTests {
    @Test func hundredthQuantizationSequence() {
        var bars = PillBars()
        bars.push(level: 1)
        var sequence: [Double] = []
        for _ in 0..<5 { bars.tick(); sequence.append(bars.smoothed) }
        #expect(sequence == [0.15, 0.27, 0.37, 0.46, 0.54])
    }

    @Test func literalParabolicProfile() {
        let expected = [0.578125, 0.744791666667, 0.869791666667, 0.953125, 0.994791666667,
                        0.994791666667, 0.953125, 0.869791666667, 0.744791666667, 0.578125]
        for i in 0..<10 { #expect(abs(PillBars.profile(i) - expected[i]) < 1e-6) }
    }

    @Test func breathingKeyframesAndSegmentEasing() {
        for (time, value) in [(0.0, 1.0), (0.2, 1.2), (0.4, 1.5), (0.8, 1.1), (0.9, 1.3)] {
            #expect(abs(PillBars.multiplier(at: time) - value) < 1e-12)
        }
        #expect(abs(PillBars.multiplier(at: 0.05) - 1.025832386) < 1e-8)
        #expect(abs(PillBars.multiplier(at: 0.1) - 1.1) < 1e-12)
        #expect(PillBars.multiplier(at: 1) == 1)
    }

    @Test func positiveDelaysHoldAndNegativeDelaysStartInCycle() {
        for delay in [0.1, 0.2, 0.3, 0.4] {
            #expect(PillBars.multiplier(at: 0, delay: delay) == 1)
            #expect(PillBars.multiplier(at: delay - 0.001, delay: delay) == 1)
        }
        #expect(abs(PillBars.multiplier(at: 0, delay: -0.2) - 1.2) < 1e-12)
    }

    @Test func heightNeverExceedsFormulaBound() {
        var bars = PillBars()
        bars.push(level: 1)
        for frame in 0..<1200 {
            bars.tick()
            #expect(bars.heights(at: Double(frame) / 60).allSatisfy { $0 <= 14.921875 })
        }
        #expect(PillBars.peakHeight == 14.921875)
        bars.reset()
        let heights = bars.heights(at: 0)
        #expect(abs(heights[0] - 1.15625) < 1e-12)
        #expect(abs(heights[4] - 1.9895833333333333) < 1e-12)
    }
}
