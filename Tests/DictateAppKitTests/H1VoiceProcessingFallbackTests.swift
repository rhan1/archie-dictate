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
            state = try CaptureVoiceProcessing.start(requested: true, builtin: true, bluetooth: false, fallbackEnabled: false,
                make: { mode in
                    self.made.append(mode)
                    return CaptureInputUnit(start: { self.running = mode }, dispose: { self.running = nil }, configure: { _ in
                        self.hardwareChannels = self.afterEnableChannels
                    }, hardwareChannels: { self.hardwareChannels })
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

    /// Real recorder with only the device factory and clock substituted. Lifecycle sees
    /// a CaptureEngine adapter so it cannot enter AudioRecorder's hardware start method.
    final class RecorderFixture: CaptureEngine {
        let clock = Clock()
        let recorder: AudioRecorder
        var events: [String] = []
        var hardwareChannels: AVAudioChannelCount = 1
        var afterEnableChannels: AVAudioChannelCount
        var running: CaptureVoiceProcessing.Unit?
        var starts = 0
        var stops = 0
        var buffers = 0
        var kept = 0
        var failure: CaptureFailure?
        var warnings: [CaptureHealth.Reason] = []
        var lifecycleFailures = 0
        var isRunning: Bool { running != nil }
        var isAllocated: Bool { isRunning }
        lazy var lifecycle: CaptureLifecycle = {
            let lifecycle = CaptureLifecycle(engine: self, scheduler: clock)
            lifecycle.onFailure = { self.lifecycleFailures += 1 }
            return lifecycle
        }()
        init(channels: AVAudioChannelCount = 1, bluetooth: Bool = false, kind: CaptureKind = .conversation) {
            afterEnableChannels = channels
            recorder = C1VoiceProcessingTests().recorder(input: bluetooth ? .bluetooth : .builtin, kind: kind)
        }
        func make(_ mode: CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit {
            events.append("make_\(mode.rawValue)")
            return CaptureInputUnit(start: {
                // The real halout closure disposes/rebuilds the whole VP graph first.
                if mode == .halout, self.running == .vpio { self.events.append("dispose_vpio") }
                self.events.append("start_\(mode.rawValue)")
                self.running = mode
            }, dispose: {
                self.events.append("dispose_\(mode.rawValue)")
                self.running = nil
            }, configure: { _ in
                self.events.append("configure_vpio")
                self.hardwareChannels = self.afterEnableChannels
            }, hardwareChannels: {
                self.events.append("read_channels")
                return self.hardwareChannels
            })
        }
        func start(device: MicChoice) throws {
            starts += 1
            try recorder.offlineStartInput(at: clock.now, make: make)
        }
        func stop() -> [Float] { stops += 1; running = nil; return recorder.stop() }
        func release() { recorder.release() }
        func rebuild() { Issue.record("Lifecycle rebuilt the capture during fallback") }
        func recoveryAdmission(_ path: RecoveryPath) -> RecoveryAdmission { recorder.recoveryAdmission(path) }
        func tick(to time: TimeInterval, deliver: Bool = false) throws {
            clock.advance(to: time)
            if deliver {
                let frames = [Float](repeating: 0.05, count: 2_400)
                kept += recorder.offlineInputFrames(frames, at: time).count
                buffers += 1
                lifecycle.bufferArrived(at: time)
            }
            let out = try recorder.offlineInputHealthTick(at: time, make: make)
            if let warn = out.warn { warnings.append(warn) }
            failure = failure ?? out.failure
        }
    }

    @Test func multichannelInputFallsBackBeforeVPTapStarts() throws {
        let f = RecorderFixture(channels: 9)
        defer { f.lifecycle.end(.cancel) }
        #expect(f.lifecycle.beginRecording(at: 0))
        let lease = try #require(f.recorder.currentLease)
        let epoch = f.lifecycle.epoch
        #expect(f.events == ["make_vpio", "configure_vpio", "read_channels", "dispose_vpio", "make_halout", "start_halout"])
        #expect(f.recorder.stats.voiceProcessing == "fallback")
        for step in 1...40 { try f.tick(to: Double(step) / 10, deliver: true) }
        #expect(f.failure == nil && f.lifecycleFailures == 0 && f.kept == 40 * 2_400)
        #expect(f.recorder.currentLease === lease && f.lifecycle.epoch === epoch)
        #expect(f.starts == 1 && f.stops == 0 && f.warnings.isEmpty)
        print("H1 GREEN vp_requested=1 hw_channels=9 fallback=multichannel_input buffers>0 outcome=ok")
    }

    @Test func silentMonoVPRestartsPlainInSameSessionAndLease() throws {
        let f = RecorderFixture()
        defer { f.lifecycle.end(.cancel) }
        #expect(f.lifecycle.beginRecording(at: 0))
        let lease = try #require(f.recorder.currentLease)
        let epoch = f.lifecycle.epoch
        try f.tick(to: 1.99)
        #expect(f.recorder.stats.voiceProcessing == "on" && f.failure == nil)
        try f.tick(to: 2)
        #expect(f.recorder.stats.voiceProcessing == "fallback" && f.failure == nil)
        #expect(f.events == ["make_vpio", "configure_vpio", "read_channels", "start_vpio", "make_halout", "dispose_vpio", "start_halout"])
        // No buffer until after lifecycle's 3 s deadline: it must defer to recorder health.
        try f.tick(to: 3.1)
        #expect(f.failure == nil && f.starts == 1 && f.stops == 0)
        #expect(f.lifecycle.warmup.phase == .warming)
        for step in 32...60 { try f.tick(to: Double(step) / 10, deliver: true) }
        #expect(f.kept == 29 * 2_400 && f.lifecycle.warmup.phase == .live)
        #expect(f.recorder.currentLease === lease && f.lifecycle.epoch === epoch)
        #expect(f.failure == nil && f.lifecycleFailures == 0)
        print("H1 GREEN vp_requested=1 hw_channels=1 no_buffer_window_elapsed=1 fallback=no_input buffers>0 outcome=ok")
    }

    @Test func healthyMonoVPKeepsProcessing() throws {
        let f = RecorderFixture()
        defer { f.lifecycle.end(.cancel) }
        #expect(f.lifecycle.beginRecording(at: 0))
        for step in 1...40 { try f.tick(to: Double(step) / 10, deliver: true) }
        #expect(f.recorder.stats.voiceProcessing == "on" && f.failure == nil)
        #expect(f.buffers == 40 && f.kept == 40 * 2_400 && !f.events.contains("make_halout"))
        print("H1 CONTROL vp_requested=1 hw_channels=1 buffers>0 fallback=none voice_processing=on")
    }

    @Test func bluetoothNeverConstructsVP() throws {
        let f = RecorderFixture(bluetooth: true)
        defer { f.lifecycle.end(.cancel) }
        #expect(f.lifecycle.beginRecording(at: 0))
        try f.tick(to: 0.1, deliver: true)
        #expect(f.events == ["make_halout", "start_halout"])
        #expect(f.recorder.stats.voiceProcessing == "unavailable" && f.kept == 2_400 && f.failure == nil)
        print("H1 CONTROL bluetooth_route voice_processing=unavailable unchanged=1")
    }

    @Test func dictationNeverRequestsVP() throws {
        let f = RecorderFixture(kind: .dictation)
        defer { f.lifecycle.end(.cancel) }
        #expect(f.lifecycle.beginRecording(at: 0))
        try f.tick(to: 0.1, deliver: true)
        #expect(f.events == ["make_halout", "start_halout"])
        #expect(f.recorder.stats.voiceProcessing == "off" && f.kept == 2_400 && f.failure == nil)
        print("H1 CONTROL dictation vp_requested=0")
    }

    @Test func silentPlainFallbackStillFailsAfterItsOwnWindow() throws {
        let f = RecorderFixture()
        defer { f.lifecycle.end(.cancel) }
        #expect(f.lifecycle.beginRecording(at: 0))
        try f.tick(to: 2)
        #expect(f.recorder.stats.voiceProcessing == "fallback" && f.failure == nil)
        try f.tick(to: 3.99)
        #expect(f.failure == nil && f.starts == 1 && f.stops == 0)
        try f.tick(to: 4)
        let failure = try #require(f.failure)
        #expect(failure.reason == .micDead && failure.health == .noInput)
        #expect(failure.durationSeconds == 4 && failure.framesKept == 0)
        #expect(f.events.filter { $0 == "start_halout" }.count == 1)
        print("H1 CONTROL plain_capture_also_silent outcome=mic_dead")
    }

}
