import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.28 FR1-B (Astra MAJOR 2 / Fable MAJOR 1): the 2.0 s window counts from when THIS recorder's headset client
/// finished its teardown (the HFP link starts collapsing then), not from `stop()`'s entry. The real `AudioRecorder`
/// with fake units and a route on HFP; the headset client's first teardown blocks 1.5 s (live: `release_ms=435`).
@Suite("V128ReleaseWindow", .serialized)
struct V128ReleaseWindowTests {
    /// `V127FirstDictationTests.SlowHeadset` whose teardown of its FIRST running session blocks `firstTeardown`.
    final class SlowStopHeadset: HeadsetCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)?
        private let lock = NSLock()
        private var epoch: CaptureEpoch?
        private var timer: DispatchSourceTimer?
        private let firstTeardown: TimeInterval
        private var starts = 0
        private var delayed = false
        init(firstTeardown: TimeInterval) { self.firstTeardown = firstTeardown }
        func start(deviceUID: String, epoch: CaptureEpoch) throws {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "v128.fake.headset"))
            timer.schedule(deadline: .now() + 0.02, repeating: 0.02)
            timer.setEventHandler { [weak self] in
                guard let self, let epoch = self.lock.withLock({ self.epoch }) else { return }
                self.onFrames?([Float](repeating: 0.2, count: 480), ProcessInfo.processInfo.systemUptime - 0.02, epoch)
            }
            lock.withLock { self.epoch = epoch; self.timer = timer; starts += 1 }
            onEvent?(.started(deviceUID: deviceUID, sampleRate: 16_000, channels: 1), epoch)
            timer.resume()
        }
        func stop() {
            let delay: TimeInterval = lock.withLock {
                let running = epoch != nil
                epoch = nil; timer?.cancel(); timer = nil
                guard running, starts == 1, !delayed else { return 0 }
                delayed = true
                return firstTeardown
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }   // the hardware release takes this long
        }
        func stop(epoch: CaptureEpoch) { if lock.withLock({ self.epoch === epoch }) { stop() } }
        var isRunning: Bool { lock.withLock { epoch != nil } }
        var lastCallbackTime: TimeInterval? { nil }
        var formatGeneration: Int { 1 }
        var counters: SourceCounters { SourceCounters() }
        let backend = "auhal"
    }

    private func session(_ recorder: AudioRecorder) async throws -> Bool {
        try await recorder.startAsync(device: .default)
        recorder.resetCapture()
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = recorder.stop()
        return recorder.stats.transientHFP
    }

    private func sleep(until deadline: TimeInterval) async throws {
        let wait = deadline - ProcessInfo.processInfo.systemUptime
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// stop at t=0, headset teardown completes at t=1.5, next start at t=2.1 → transient (0.6 s after the release);
    /// control: a start 2.5 s after an immediate release stays warm.
    @Test func windowCountsFromTheHeadsetTeardown() async throws {
        var route = V127FirstDictationTests.route
        route.hfpAlready = { true }
        let headset = SlowStopHeadset(firstTeardown: 1.5)
        let recorder = AudioRecorder(builtin: { V127FirstDictationTests.SlowBuiltin(startBlocks: 0) },
                                     headset: { headset }, backend: .auhal, broker: CaptureLeaseBroker(), route: route)
        let first = try await session(recorder)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        _ = await recorder.awaitRelease()                      // ≈ 1.5 s: the headset's teardown
        let releasedAfter = ProcessInfo.processInfo.systemUptime - stoppedAt
        try await sleep(until: stoppedAt + 2.1)
        let delayed = try await session(recorder)
        let delayedNote = recorder.classificationNote
        _ = await recorder.awaitRelease()
        try await sleep(until: ProcessInfo.processInfo.systemUptime + 2.5)
        let control = try await session(recorder)
        _ = await recorder.awaitRelease()
        print("FR1-B LITERAL first=\(first) released_after_ms=\(Int(releasedAfter * 1000)) delayed_teardown transient=\(delayed) \(delayedNote) control_released_2_5s_before transient=\(control)")
        #expect(!first)
        #expect(delayed)
        #expect(!control)
    }
}
