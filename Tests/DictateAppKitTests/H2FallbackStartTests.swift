import AVFoundation
import CoreAudio
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

@Suite(.serialized)
struct H2FallbackStartTests {
    /// Native operations are closures: no engine, device lookup, real sleep or home-path IO.
    final class Fixture {
        let recorder: AudioRecorder
        let clock = H1VoiceProcessingFallbackTests.Clock()
        var selector = CaptureBuiltInSelector()
        var selects = 0
        var starts = 0
        var frames = 0
        var failures = 1
        var defaultBuiltIn = false
        var hardwareReady = true
        var channels: AVAudioChannelCount = 9
        var status = kAudioHardwareBadDeviceError
        var disableFails = false
        var inspectHealthDuringWait = true
        var healthDuringWait: [CaptureFeed.TickOutput] = []
        var waits: [TimeInterval] = []
        var events: [String] = []
        var notes: [String] = []
        var vpRequested = 0
        var vpAllocated = false

        init(legacy: Bool = false, input: CaptureBridge.DefaultInput = .builtin,
             kind: CaptureKind = .conversation) {
            recorder = C1VoiceProcessingTests().recorder(input: input, kind: kind)
            selector.legacySingleAttempt = legacy
            selector.defaultIsBuiltIn = { [unowned self] in self.defaultBuiltIn }
            selector.sleep = { [unowned self] delay in
                self.waits.append(delay)
                self.clock.advance(to: self.clock.now + delay)
                if self.inspectHealthDuringWait {
                    do {
                        self.healthDuringWait.append(try self.recorder.offlineInputHealthTick(at: self.clock.now, make: self.make))
                    } catch { Issue.record("Health attempted a second fallback during selection") }
                }
            }
        }
        func make(_ mode: CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit {
            events.append("make_\(mode.rawValue)")
            if mode == .vpio { vpRequested += 1 }
            return CaptureInputUnit(start: {
                if mode == .halout, self.vpAllocated { self.disposeVP() }
                if mode == .halout, self.recorder.stats.voiceProcessing == "fallback" {
                    try self.selector.run(hardwareFormatValid: { self.hardwareReady }, select: {
                        self.selects += 1
                        if self.selects <= self.failures {
                            throw NSError(domain: NSOSStatusErrorDomain, code: Int(self.status))
                        }
                    }, note: { self.notes.append($0) })
                }
                self.recorder.offlineInputStarted {
                    self.events.append("start_\(mode.rawValue)")
                    self.starts += 1
                }
            }, dispose: { self.disposeVP() }, configure: { _ in self.vpAllocated = true },
                hardwareChannels: { self.channels })
        }
        func disposeVP() {
            if !selector.legacySingleAttempt {
                CaptureVoiceProcessing.disableBeforeTeardown({
                    self.events.append("disable_vpio")
                    if self.disableFails { throw NSError(domain: NSOSStatusErrorDomain, code: -1) }
                }, note: { self.notes.append($0) })
            }
            events.append("dispose_vpio")
            vpAllocated = false
        }
        func start() throws {
            try recorder.offlineStartInput(at: clock.now, now: { self.clock.now }, note: { self.notes.append($0) }, make: make)
        }
        func deliver() {
            let time = clock.now + 0.1
            clock.advance(to: time)
            frames += recorder.offlineInputFrames([Float](repeating: 0.05, count: 2_400), at: time).count
        }
        func finish() -> [Float] { recorder.stop() }
        func requireHealthy() throws {
            try #require(healthDuringWait.allSatisfy { $0.warn == nil && $0.failure == nil && $0.notes.isEmpty })
            let health = try recorder.offlineInputHealthTick(at: clock.now, make: make)
            try #require(health.warn == nil && health.failure == nil)
        }
    }

    @Test func legacySingleSelectFailsAfterMultichannelRefusal() throws {
        let f = Fixture(legacy: true)
        defer { _ = f.finish() }
        var caught: NSError?
        do { try f.start() } catch { caught = error as NSError }
        try #require(caught?.domain == NSOSStatusErrorDomain && caught?.code == 560227702)
        try #require(f.recorder.stats.voiceProcessing == "fallback")
        try #require(f.events == ["make_vpio", "dispose_vpio", "make_halout"])
        try #require(f.selects == 1 && f.starts == 0 && f.frames == 0 && f.waits.isEmpty)
        try #require(f.recorder.stats.ioOps.hasPrefix("io_ops=start:0"))
        print("H2 RED fallback=multichannel_input select_err=!dev outcome=mic_start frames=0")
    }

    @Test func oneTransientSelectFailureStartsAndDelivers() throws {
        let f = Fixture()
        try f.start()
        try #require(f.selects == 2 && f.starts == 1 && f.vpRequested == 1)
        try #require(f.waits == [0.15] && f.notes.contains("builtin_select_retry=1"))
        try #require(f.events == ["make_vpio", "disable_vpio", "dispose_vpio", "make_halout", "start_halout"])
        try f.requireHealthy()
        f.deliver()
        try f.requireHealthy()
        let captured = f.finish()
        try #require(captured.count == 2_400 && f.frames == 2_400)
        try #require(f.recorder.stats.voiceProcessing == "fallback")
        try #require(f.recorder.stats.builtinFramesAfterFallback == 2_400)
        try #require(f.recorder.stats.ioOps.hasPrefix("io_ops=start:1"))
        print("H2 GREEN fallback=multichannel_input select_retry=1 io_ops=start:1 frames>0 outcome=ok")
        try #require(f.notes.contains("vp_disabled_before_teardown=1"))
        print("H2 CONTROL vp_disabled_before_teardown=1")
    }

    @Test func defaultBuiltInSkipsExplicitSelect() throws {
        let f = Fixture()
        f.defaultBuiltIn = true
        f.failures = .max
        try f.start()
        f.deliver()
        try f.requireHealthy()
        let captured = f.finish()
        try #require(f.selects == 0 && f.waits.isEmpty && f.starts == 1 && captured.count == 2_400)
        try #require(f.notes.contains("builtin_select=skipped_default"))
        try #require(f.recorder.stats.builtinFramesAfterFallback == 2_400)
        print("H2 GREEN fallback=multichannel_input select=skipped_default frames>0 outcome=ok")
    }

    @Test func defaultBuiltInWithInvalidFormatRequiresExplicitSelect() throws {
        let f = Fixture()
        f.defaultBuiltIn = true
        f.hardwareReady = false
        f.failures = 0
        try f.start()
        f.deliver()
        let captured = f.finish()
        try #require(f.selects == 1 && f.starts == 1 && captured.count == 2_400)
        try #require(!f.notes.contains("builtin_select=skipped_default"))
    }

    @Test func persistentSelectionFailsWithinBoundAndReportsFallbackFailure() throws {
        let f = Fixture()
        f.failures = .max
        var caught: NSError?
        do { try f.start() } catch { caught = error as NSError }
        try #require(caught?.code == 560227702 && f.selects == 10 && f.starts == 0 && f.frames == 0)
        try #require(f.waits.count == 9 && abs(f.clock.now - 1.35) < 0.000001)
        try #require(f.notes.filter { $0.hasPrefix("builtin_select_retry=") }.count == 9)
        try #require(f.healthDuringWait.count == 9)
        try #require(f.healthDuringWait.allSatisfy { $0.warn == nil && $0.failure == nil })
        try #require(f.notes.contains { $0.contains("voice_processing=fallback_failed reason=select_err=560227702") })
        let captured = f.finish()
        try #require(captured.isEmpty && f.recorder.currentLease == nil)
        try #require(f.recorder.stats.ioOps.hasPrefix("io_ops=start:0"))
        print("H2 CONTROL select_err_persistent outcome=mic_start fallback_failed=1 hang=0")
    }

    @Test func healthWindowBeginsAfterLastRetryAndStillExpires() throws {
        let f = Fixture()
        defer { _ = f.finish() }
        f.failures = 9
        try f.start()
        try #require(f.selects == 10 && f.starts == 1 && f.clock.now > 1)
        try f.requireHealthy()
        let before = try f.recorder.offlineInputHealthTick(at: f.clock.now + 1.99, make: f.make)
        try #require(before.failure == nil)
        let expired = try f.recorder.offlineInputHealthTick(at: f.clock.now + 2, make: f.make)
        try #require(expired.failure?.reason == .micDead && expired.failure?.health == .noInput)
    }

    @Test func firstBufferTimeoutFallbackAlsoWaitsForPlainStart() throws {
        let f = Fixture()
        defer { _ = f.finish() }
        f.channels = 1
        try f.start()
        f.clock.advance(to: 2)
        let expired = try f.recorder.offlineInputHealthTick(at: f.clock.now, now: { f.clock.now }, make: f.make)
        try #require(expired.failure == nil && f.recorder.stats.voiceProcessing == "fallback")
        try #require(f.selects == 2 && f.starts == 2)
        try #require(f.events == ["make_vpio", "start_vpio", "make_halout", "disable_vpio", "dispose_vpio", "start_halout"])
        try #require(f.notes.contains("vp_disabled_before_teardown=1"))
        try f.requireHealthy()
        f.deliver()
        try f.requireHealthy()
        try #require(f.frames == 2_400)
    }

    @Test func disableFailureDoesNotPreventPlainStart() throws {
        let f = Fixture()
        f.disableFails = true
        try f.start()
        f.deliver()
        let captured = f.finish()
        try #require(f.notes.contains("vp_disable_error=-1") && !f.notes.contains("vp_disabled_before_teardown=1"))
        try #require(f.events.contains("dispose_vpio") && captured.count == 2_400)
    }

    @Test func disableObjCExceptionIsCaughtBeforeDrop() throws {
        var notes: [String] = []
        var dropped = false
        CaptureVoiceProcessing.disableBeforeTeardown({
            NSException(name: .invalidArgumentException, reason: "fixture", userInfo: nil).raise()
        }, note: { notes.append($0) })
        dropped = true
        try #require(dropped && notes.count == 1 && notes[0].hasPrefix("vp_disable_error="))
    }

    @Test func legacyDefaultStillSelectsAndFails() throws {
        let f = Fixture(legacy: true)
        defer { _ = f.finish() }
        f.defaultBuiltIn = true
        var caught = false
        do { try f.start() } catch { caught = true }
        try #require(caught && f.selects == 1 && f.starts == 0 && f.waits.isEmpty)
        try #require(!f.notes.contains("builtin_select=skipped_default"))
    }

    @Test func bluetoothRouteUnchanged() throws {
        let f = Fixture(input: .bluetooth)
        try f.start()
        f.deliver()
        let captured = f.finish()
        try #require(f.vpRequested == 0 && f.selects == 0 && f.waits.isEmpty && f.starts == 1)
        try #require(f.recorder.stats.voiceProcessing == "unavailable" && captured.count == 2_400)
        try #require(f.recorder.stats.builtinFramesAfterFallback == 0)
        try #require(f.events == ["make_halout", "start_halout"])
        print("H2 CONTROL bluetooth_route unchanged=1")
    }

    @Test func dictationUnchanged() throws {
        let f = Fixture(kind: .dictation)
        try f.start()
        f.deliver()
        let captured = f.finish()
        try #require(f.vpRequested == 0 && f.selects == 0 && f.waits.isEmpty && f.starts == 1)
        try #require(f.recorder.stats.voiceProcessing == "off" && captured.count == 2_400)
        try #require(f.recorder.stats.builtinFramesAfterFallback == 0)
        try #require(f.events == ["make_halout", "start_halout"])
        print("H2 CONTROL dictation unchanged=1")
    }

    @Test func hostPreferenceOffNeverRequestsVPAndDelivers() throws {
        // Archie's existing off switch supplies the non-VP kind to DictateKit.
        // The preference itself belongs to Archie, which this task does not edit.
        let f = Fixture(kind: .dictation)
        try f.start()
        f.deliver()
        let captured = f.finish()
        try #require(f.vpRequested == 0 && f.recorder.stats.voiceProcessing == "off")
        try #require(captured.count == 2_400 && f.selects == 0 && f.waits.isEmpty)
        print("H2 CONTROL pref=off vp_requested=0 frames>0")
    }

    @Test func everyHALStatusRetriesButOtherErrorsDoNot() throws {
        let statuses: [OSStatus] = [kAudioHardwareNotRunningError, kAudioHardwareUnspecifiedError,
            kAudioHardwareUnknownPropertyError, kAudioHardwareBadPropertySizeError,
            kAudioHardwareIllegalOperationError, kAudioHardwareBadObjectError, kAudioHardwareBadDeviceError,
            kAudioHardwareBadStreamError, kAudioHardwareUnsupportedOperationError, kAudioHardwareNotReadyError]
        for status in statuses {
            let f = Fixture()
            f.status = status
            try f.start()
            f.deliver()
            let captured = f.finish()
            try #require(f.selects == 2 && f.waits == [0.15] && captured.count == 2_400)
        }
        for (domain, code) in [(NSOSStatusErrorDomain, -50), ("Other", 560227702)] {
            var calls = 0, waits = 0
            let selector = CaptureBuiltInSelector(defaultIsBuiltIn: { false }, sleep: { _ in waits += 1 })
            var caught = false
            do {
                try selector.run(select: { calls += 1; throw NSError(domain: domain, code: code) }, note: { _ in })
            } catch { caught = true }
            try #require(caught && calls == 1 && waits == 0)
        }
    }

    @Test func rebuildSelectionSharesTheSameTenAttemptBudget() throws {
        let budget = CaptureBuiltInSelector.Budget()
        var calls = 0, waits = 0
        let selector = CaptureBuiltInSelector(defaultIsBuiltIn: { false }, sleep: { _ in waits += 1 })
        try selector.run(budget: budget, select: { calls += 1 }, note: { _ in })
        var caught = false
        do {
            try selector.run(budget: budget, select: {
                calls += 1; throw NSError(domain: NSOSStatusErrorDomain, code: 560947818)
            }, note: { _ in })
        } catch { caught = true }
        try #require(caught && calls == 10 && waits == 8 && budget.attempts == 10)
    }
}
