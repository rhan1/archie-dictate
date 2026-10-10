import Foundation
import Testing
@testable import DictateCore

/// D0b: built-in audio is ring-buffered from the first ⌥ tap; the second tap keeps
/// boundary − 150 ms onwards. Frames are 24 kHz mono; values encode their index.
@Suite("CaptureRing")
struct CaptureRingTests {
    private let rate = 24_000.0
    private func frames(_ start: Int, _ count: Int) -> [Float] { (start..<(start + count)).map(Float.init) }

    @Test func capacityIsBoundedAtOneSecond() {
        var ring = CaptureRing()
        #expect(ring.capacity == 24_000 && CaptureRing.preRoll == 0.15)
        for i in 0..<30 { ring.append(frames(i * 1200, 1200), at: Double(i) * 0.05) } // 1.5 s pushed
        #expect(ring.count == 24_000)
        #expect(abs((ring.oldestTime ?? 0) - 0.5) < 1e-9) // oldest 0.5 s overwritten
    }

    @Test func keepsFromBoundaryMinusPreRoll() {
        var ring = CaptureRing()
        for i in 0..<8 { ring.append(frames(i * 1200, 1200), at: 1 + Double(i) * 0.05) } // 1.00 ..< 1.40
        let kept = ring.drain(from: 1.35 - CaptureRing.preRoll) // tap at 1.35 → keep 1.20 onwards
        #expect(kept.count == 4800)
        #expect(kept.first == 4800 && kept.last == Float(8 * 1200 - 1))
        #expect(ring.count == 0)
        let again = ring.drain(from: 0)
        #expect(again.isEmpty) // drain empties
    }

    @Test func boundaryInsideAChunkSplitsAtTheExactFrame() {
        var ring = CaptureRing()
        ring.append(frames(0, 2400), at: 10)
        let kept = ring.drain(from: 10.05)
        #expect(kept == frames(1200, 1200))
    }

    @Test func wraparoundKeepsChronologicalOrder() {
        var ring = CaptureRing(capacity: 1000)
        ring.append(frames(0, 700), at: 0)
        ring.append(frames(700, 700), at: 700 / rate) // wraps; oldest 400 overwritten
        #expect(ring.count == 1000)
        let kept = ring.drain(from: 0)
        #expect(kept == frames(400, 1000))
        // A single push larger than the ring keeps only its newest capacity frames.
        ring.append(frames(0, 2500), at: 5)
        #expect(ring.count == 1000 && abs((ring.oldestTime ?? 0) - (5 + 1500 / rate)) < 1e-9)
        let newest = ring.drain(from: 0)
        #expect(newest == frames(1500, 1000))
    }

    @Test func gapsKeepTheirOwnTimestamps() {
        var ring = CaptureRing()
        ring.append(frames(0, 1200), at: 1.0)     // 1.00 ..< 1.05
        ring.append(frames(5000, 1200), at: 1.2)  // gap, then 1.20 ..< 1.25
        let kept = ring.drain(from: 1.03)
        #expect(kept == frames(720, 480) + frames(5000, 1200))
    }

    @Test func removeAllDiscards() {
        var ring = CaptureRing()
        ring.append(frames(0, 2400), at: 0)
        ring.removeAll()
        let kept = ring.drain(from: 0)
        #expect(ring.count == 0 && ring.oldestTime == nil && kept.isEmpty)
    }
}

/// The recorder's single serialized path: arbitration + ring + kept frames.
@Suite("CaptureFeed")
struct CaptureFeedTests {
    private func frames(_ start: Int, _ count: Int) -> [Float] { (start..<(start + count)).map(Float.init) }
    private func bluetooth() -> CaptureFeed {
        var feed = CaptureFeed()
        feed.start(defaultInput: .bluetooth, hasBuiltin: true)
        return feed
    }

    @Test func builtinPreRollIsKeptAtTheSecondTap() {
        var feed = bluetooth()
        // First tap at 0; built-in buffers of 50 ms from 0.10 to 0.35.
        for i in 0..<5 {
            let out = feed.accept(frames(i * 1200, 1200), source: .builtin, at: 0.10 + Double(i) * 0.05)
            #expect(out.frames.isEmpty)
        }
        let kept = feed.recordingStarted(at: 0.35)
        #expect(kept == frames(2400, 3600)) // 0.20 ..< 0.35 = 150 ms
        #expect(feed.bridge.firstKeptMs == 0)
        let live = feed.accept(frames(6000, 1200), source: .builtin, at: 0.35)
        #expect(live.frames == frames(6000, 1200))
    }

    @Test func handoverAfterPreRollIsExact() {
        var feed = bluetooth()
        var pipeline: [Float] = []
        for i in 0..<5 { _ = feed.accept(frames(i * 1200, 1200), source: .builtin, at: 0.10 + Double(i) * 0.05) }
        pipeline += feed.recordingStarted(at: 0.35)
        pipeline += feed.accept(frames(6000, 1200), source: .builtin, at: 0.35).frames
        pipeline += feed.accept(frames(7200, 1200), source: .builtin, at: 0.40).frames
        // v1.7: 110 ms of earlier headset signal (not fed) qualifies the takeover.
        #expect(feed.accept(Array(repeating: -1, count: 2640), source: .headset, at: 0.31).frames.isEmpty)
        // The switching headset buffer overlaps the last 30 ms of built-in audio (0.42 ..< 0.47).
        let switched = feed.accept(Array(repeating: -1, count: 1200), source: .headset, at: 0.42, arrivedAt: 1.5)
        #expect(switched.releaseBuiltin && switched.frames.count == 480)
        pipeline += switched.frames
        pipeline += feed.accept(frames(9000, 1200), source: .builtin, at: 0.45).frames // late built-in: ignored
        pipeline += feed.accept(Array(repeating: -2, count: 1200), source: .headset, at: 0.47).frames
        // 0.20 ..< 0.52 with no gap and no duplicate.
        #expect(pipeline.count == 7680)
        #expect(Array(pipeline.prefix(6000)) == frames(2400, 6000))
        #expect(feed.bridge.bridgeMs == 1150 && feed.bridge.state == .switched)
    }

    @Test func loneTapDiscardsTheRing() {
        var feed = bluetooth()
        for i in 0..<5 { _ = feed.accept(frames(i * 1200, 1200), source: .builtin, at: 0.10 + Double(i) * 0.05) }
        #expect(feed.ring.count == 6000) // positive control
        let release = feed.cancel()
        #expect(release) // still owned the built-in input: release it
        #expect(feed.ring.count == 0)
        // Late buffers from the cancelled session never reach a later dictation.
        let late = feed.accept(frames(0, 1200), source: .builtin, at: 0.4)
        #expect(late.frames.isEmpty && feed.ring.count == 0)
        feed.start(defaultInput: .bluetooth, hasBuiltin: true)
        let none = feed.recordingStarted(at: 1)
        #expect(none.isEmpty && feed.bridge.firstKeptMs == nil)
    }

    @Test func defaultBuiltinMicAlsoKeepsPreRoll() {
        var feed = CaptureFeed()
        feed.start(defaultInput: .builtin, hasBuiltin: true) // the engine's own default IS the built-in mic
        for i in 0..<4 { _ = feed.accept(frames(i * 1200, 1200), source: .headset, at: 0.15 + Double(i) * 0.05) }
        let kept = feed.recordingStarted(at: 0.35)
        #expect(kept == frames(1200, 3600)) // 0.20 ..< 0.35
        #expect(feed.bridge.firstKeptMs == 0)
    }

    @Test func coldEngineMeasuresTapToFirstKeptBuffer() {
        var feed = bluetooth()
        let cold = feed.recordingStarted(at: 2)
        #expect(cold.isEmpty && feed.bridge.firstKeptMs == nil)
        _ = feed.accept(frames(0, 1200), source: .builtin, at: 2.0, arrivedAt: 2.04)
        #expect(feed.bridge.firstKeptMs == 40)
        _ = feed.accept(frames(0, 1200), source: .builtin, at: 2.05, arrivedAt: 2.09)
        #expect(feed.bridge.firstKeptMs == 40) // first kept buffer only
    }
}
