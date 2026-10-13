import Foundation
import Testing
@testable import DictateCore

/// v1.13 (L1 review): the health clock's zeros switch must agree with the bridge's content-clock
/// witness. A headset whose buffers carry correct timestamps but ARRIVE late (100 ms engine buffers,
/// delivered 60 ms after their last frame) is digitally silent through a 2 s pause; at the first word
/// after it the built-in's 10 ms buffers have reached 150 ms of speech before the headset's word has
/// arrived. On arrival times that looks like a dead link; on the sample clock the headset was silent
/// only while nobody spoke.
@Suite("PauseHealth")
struct PauseHealthTests {
    static func speech(_ t: TimeInterval) -> Bool { t < 10.5 || t >= 12.5 }
    static func sample(_ i: Int, at t: TimeInterval, gain: Float) -> Float {
        speech(t) ? gain * Float(sin(Double(i) * 0.37) * (0.6 + 0.4 * sin(Double(i) * 0.0011))) : 0
    }

    @Test func aLateHeadsetBufferAfterAPauseIsNotADeadLink() {
        var feed = CaptureFeed()
        feed.start(defaultInput: .bluetooth, hasBuiltin: true)
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        var notes: [String] = []
        var pending: [(arrival: TimeInterval, start: TimeInterval, frames: [Float])] = []
        var nextTick = 10.05
        for k in 0..<300 {
            let t = 10 + Double(k) * 0.01
            let now = t + 0.01
            let builtin = (0..<240).map { j -> Float in
                let i = k * 240 + j
                return Self.sample(i, at: 10 + Double(i) / 24_000, gain: 0.05) + (j % 2 == 0 ? 0.0005 : -0.0005)
            }
            notes += feed.accept(builtin, source: .builtin, at: t, arrivedAt: now).notes
            if k % 10 == 9 {
                let start = t - 0.09
                let first = (k - 9) * 240
                pending.append((now + 0.06, start, (0..<2_400).map { Self.sample(first + $0, at: start + Double($0) / 24_000, gain: 0.3) }))
            }
            while let due = pending.first, due.arrival <= now + 1e-9 {
                pending.removeFirst()
                notes += feed.accept(due.frames, source: .headset, at: due.start, arrivedAt: due.arrival).notes
            }
            while nextTick <= now + 1e-9 {
                notes += feed.tick(at: nextTick).notes
                nextTick += 0.1
            }
        }
        let carrier = feed.timeline.carrierIntervals(endMs: 3_000)
        print("PauseHealth carrier=\(carrier) switches=\(notes.filter { $0.hasPrefix("bridge_switch") })")
        #expect(!notes.contains { $0.hasPrefix("bridge_switch=builtin") }, "\(carrier)")
        #expect(carrier.split(separator: ",").count == 2, "\(carrier)")       // the takeover, nothing after
    }
}
