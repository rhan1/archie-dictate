import AVFoundation
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

@Suite(.serialized)
struct H1VoiceProcessingFallbackTests {
    /// Manual scheduler: no audio engines, device queries, real sleeps, or file writes.
    final class Clock: CaptureScheduler {
        final class Job: CaptureCancellation {
            let due: TimeInterval
            let action: () -> Void
            var cancelled = false
            init(_ due: TimeInterval, _ action: @escaping () -> Void) { self.due = due; self.action = action }
            func cancel() { cancelled = true }
        }
        var now: TimeInterval = 0
        var jobs: [Job] = []
        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CaptureCancellation {
            let job = Job(now + delay, action); jobs.append(job); return job
        }
        func advance(to target: TimeInterval) {
            while let job = jobs.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
                job.cancel(); now = job.due; job.action()
            }
            now = target
        }
    }

    /// A fake device's VP enable changes its hardware from mono to 48 kHz/9ch;
    /// that graph then supplies no callbacks. Policy, feed, health and lifecycle are real.
    final class Fixture: CaptureEngine {
        let clock = Clock()
        let epoch = CaptureEpoch()
        var feed = CaptureFeed()
        var state = CaptureVoiceProcessing.State.off
        var notes: [String] = []
        var made: [CaptureVoiceProcessing.Unit] = []
        var hardwareChannels: AVAudioChannelCount = 1
        var afterEnableChannels: AVAudioChannelCount = 9
        var hardwareRate: Double = 48_000
        var running: CaptureVoiceProcessing.Unit?
        var buffers = 0
        var failure: CaptureFailure?
        var isRunning: Bool { running != nil }
        var isAllocated: Bool { isRunning }
        lazy var lifecycle = CaptureLifecycle(engine: self, scheduler: clock)
        func start(device: MicChoice) throws {
            feed.start(defaultInput: .builtin, hasBuiltin: true, epoch: epoch)
            feed.sourceStarted(.headset, at: clock.now)
            _ = feed.recordingStarted(at: clock.now)
            state = try CaptureVoiceProcessing.start(requested: true, builtin: true, bluetooth: false,
                make: { mode in
                    self.made.append(mode)
                    return CaptureInputUnit(start: { self.running = mode }, dispose: { self.running = nil }, configure: { _ in
                        self.hardwareChannels = self.afterEnableChannels
                    })
                }, note: { self.notes.append($0) })
        }
        func stop() -> [Float] { running = nil; return [] }
        func release() { _ = stop() }
        func rebuild() {}
        func tick(at time: TimeInterval) {
            clock.advance(to: time)
            let out = feed.tick(at: time)
            notes += out.notes
            failure = out.failure ?? failure
        }
    }

    /// Labelled historical selector: retained after the fix to document the pre-fix chain.
    @Test func oldSelectorAcceptsSilentNineChannelVPThenHealthFails() throws {
        let f = Fixture()
        #expect(f.lifecycle.beginRecording(at: 0))
        #expect(f.hardwareRate == 48_000 && f.hardwareChannels == 9)
        #expect(f.made == [.vpio] && f.state == .on && f.buffers == 0)
        f.tick(at: 1.1)
        #expect(f.notes == ["voice_processing=on", "health=warn reason=no_input"])
        #expect(f.failure == nil)
        f.tick(at: CaptureHealth.failAfter)
        #expect(f.failure?.reason == .micDead && f.failure?.health == .noInput)
        #expect(f.lifecycle.warmup.phase == .warming)
        print("H1 RED vp_requested=1 hw_channels=9 buffers=0 outcome=mic_dead")
        f.lifecycle.end(.cancel)
    }
}
