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
        var hardwareFormat = TapFormatPlan.Format(sampleRate: 48_000, channels: 1)
        var hardwareReady: Bool {
            get { hardwareFormat.isValid }
            set { hardwareFormat = .init(sampleRate: newValue ? 48_000 : 0, channels: newValue ? 1 : 0) }
        }
        /// RED control: H2 before the real-hardware correction skipped solely on default identity
        /// and let a zero-format Mismatch escape without a format wait/rebuild/select retry.
        var legacySkipDefaultWithoutFormat = false
        var readyAfterSelect = false
        var formatReadFailures = 0
        var formatReads = 0
        var rebuilds = 0
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
                    if self.legacySkipDefaultWithoutFormat {
                        let budget = CaptureBuiltInSelector.Budget()
                        let legacySelect = {
                            try self.selector.run(budget: budget, hardwareFormatValid: { true },
                                select: self.selectBuiltIn, note: { self.notes.append($0) })
                        }
                        try legacySelect()
                        _ = try TapFormatPlan.run(device: .builtIn, formats: {
                            (self.hardwareFormat, .init(sampleRate: 44_100, channels: 2))
                        }, align: { Issue.record("Invalid hardware must not align") }, rebuild: {
                            self.rebuilds += 1
                            try legacySelect()
                        })
                    } else {
                        try self.selector.startFallback(hardwareFormatValid: { self.hardwareReady }, select: {
                            try self.selectBuiltIn()
                        }, rebuild: { self.rebuilds += 1 }, start: {
                            try self.checkFormat()
                        }, note: { self.notes.append($0) })
                    }
                }
                self.recorder.offlineInputStarted {
                    self.events.append("start_\(mode.rawValue)")
                    self.starts += 1
                }
            }, dispose: { self.disposeVP() }, configure: { _ in self.vpAllocated = true },
                hardwareChannels: { self.channels })
        }
        func selectBuiltIn() throws {
            selects += 1
            if selects <= failures {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            if readyAfterSelect { hardwareReady = true }
        }
        func checkFormat() throws {
            formatReads += 1
            if !hardwareReady || formatReads <= formatReadFailures {
                let hardware = formatReads <= formatReadFailures
                    ? TapFormatPlan.Format(sampleRate: 0, channels: 0) : hardwareFormat
                throw TapFormatPlan.Mismatch(hardware: hardware,
                                             output: .init(sampleRate: 44_100, channels: 2))
            }
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
        try #require(f.hardwareFormat.isValid && f.formatReads == 1)
        try #require(f.selects == 0 && f.waits.isEmpty && f.starts == 1 && captured.count == 2_400)
        try #require(f.notes.contains("builtin_select=skipped_default"))
        try #require(f.recorder.stats.builtinFramesAfterFallback == 2_400)
        print("H2 GREEN fallback=multichannel_input select=skipped_default frames>0 outcome=ok")
    }

    @Test func defaultBuiltInWithInvalidFormatRequiresExplicitSelect() throws {
        let f = Fixture()
        f.defaultBuiltIn = true
        f.hardwareReady = false
        f.readyAfterSelect = true
        f.failures = 0
        try f.start()
        f.deliver()
        let captured = f.finish()
        try #require(f.selects == 1 && f.starts == 1 && captured.count == 2_400)
        try #require(!f.notes.contains("builtin_select=skipped_default"))
        try #require(f.hardwareReady && f.formatReads == 1 && f.waits.isEmpty)
        try #require(f.recorder.stats.builtinFramesAfterFallback == 2_400)
        try #require(!f.notes.contains { $0.contains("fallback_failed") })
        print("H2 GREEN fallback=multichannel_input hw_format_not_ready=1 select=explicit frames>0 outcome=ok")
    }

    @Test func legacyDefaultSkipWithZeroFormatFailsBeforeCapture() throws {
        let f = Fixture()
        f.legacySkipDefaultWithoutFormat = true
        f.defaultBuiltIn = true
        f.hardwareReady = false
        f.readyAfterSelect = true
        f.failures = 0
        var caught: Error?
        do { try f.start() } catch { caught = error }
        try #require(caught.map(CaptureBuiltInSelector.isFormatNotReady) == true)
        try #require(f.notes.filter { $0 == "builtin_select=skipped_default" }.count == 2)
        try #require(f.notes.contains { $0.hasPrefix("voice_processing=fallback_failed reason=") })
        try #require(f.selects == 0 && f.rebuilds == 1 && f.waits.isEmpty)
        try #require(f.starts == 0 && f.frames == 0 && f.recorder.stats.builtinFramesAfterFallback == 0)
        try #require(f.recorder.stats.ioOps.hasPrefix("io_ops=start:0"))
        try #require(f.finish().isEmpty && f.recorder.currentLease == nil)
        print("H2 RED fallback=multichannel_input select=skipped_default hw_format=0Hz/0ch outcome=mic_start frames=0")
    }

    @Test func formatRecoveryRebuildsAndExplicitlySelectsWithinSharedBudget() throws {
        let f = Fixture()
        f.defaultBuiltIn = true
        f.hardwareReady = false
        f.readyAfterSelect = true
        f.failures = 0
        f.formatReadFailures = 2
        try f.start()
        f.deliver()
        try f.requireHealthy()
        let captured = f.finish()
        try #require(f.formatReads == 3 && f.rebuilds == 2 && f.selects == 3)
        try #require(!f.notes.contains("builtin_select=skipped_default"))
        try #require(f.waits == [0.15, 0.15] && captured.count == 2_400)
        try #require(f.notes.contains("builtin_format_retry=1") && f.notes.contains("builtin_format_retry=2"))
        try #require(f.recorder.stats.builtinFramesAfterFallback == 2_400)
        try #require(!f.notes.contains { $0.contains("fallback_failed") })
        print("H2 GREEN fallback=multichannel_input builtin_format_retry=2 frames>0 outcome=ok")
    }

    @Test func formatNeverReadyFailsWithinTheSameBudget() throws {
        let f = Fixture()
        f.defaultBuiltIn = true
        f.hardwareReady = false
        f.failures = 0
        var caught: Error?
        do { try f.start() } catch { caught = error }
        try #require(caught.map(CaptureBuiltInSelector.isFormatNotReady) == true)
        try #require(f.selects == 10 && f.formatReads == 10 && f.rebuilds == 9)
        try #require(f.waits.count == 9 && f.clock.now <= 1.5 && abs(f.clock.now - 1.35) < 0.000001)
        try #require(f.starts == 0 && f.frames == 0)
        try #require(f.notes.contains("voice_processing=fallback_failed reason=format_not_ready"))
        try #require(f.healthDuringWait.allSatisfy { $0.warn == nil && $0.failure == nil })
        try #require(f.finish().isEmpty && f.recorder.currentLease == nil)
        print("H2 CONTROL format_never_ready fallback_failed=1 reason=format_not_ready hang=0")
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

    @Test func eitherMissingHardwareRateOrChannelsPreventsDefaultSkip() throws {
        for hardware in [TapFormatPlan.Format(sampleRate: 0, channels: 1),
                         TapFormatPlan.Format(sampleRate: 48_000, channels: 0)] {
            let f = Fixture()
            f.defaultBuiltIn = true
            f.hardwareFormat = hardware
            f.readyAfterSelect = true
            f.failures = 0
            try f.start()
            f.deliver()
            let captured = f.finish()
            try #require(f.selects == 1 && f.waits.isEmpty && captured.count == 2_400)
            try #require(!f.notes.contains("builtin_select=skipped_default"))
        }
    }

    @Test func selectAndFormatFailuresShareOneBudgetWithLastAttemptPositiveControl() throws {
        for neverReady in [false, true] {
            let f = Fixture()
            f.failures = 8
            f.formatReadFailures = neverReady ? .max : 1
            var caught: Error?
            do { try f.start() } catch { caught = error }
            try #require(f.selects == 10 && f.formatReads == 2 && f.rebuilds == 1)
            try #require(f.waits.count == 9 && abs(f.clock.now - 1.35) < 0.000001)
            try #require(f.notes.filter { $0.hasPrefix("builtin_select_retry=") }.count == 8)
            try #require(f.notes.filter { $0.hasPrefix("builtin_format_retry=") } == ["builtin_format_retry=1"])
            try #require(f.healthDuringWait.count == 9)
            try #require(f.healthDuringWait.allSatisfy { $0.warn == nil && $0.failure == nil && $0.notes.isEmpty })
            if neverReady {
                try #require(caught.map(CaptureBuiltInSelector.isFormatNotReady) == true && f.starts == 0)
                try #require(f.notes.contains("voice_processing=fallback_failed reason=format_not_ready"))
                try #require(f.finish().isEmpty)
            } else {
                try #require(caught == nil && f.starts == 1)
                try f.requireHealthy()
                f.deliver()
                try f.requireHealthy()
                try #require(f.finish().count == 2_400 && f.recorder.stats.builtinFramesAfterFallback == 2_400)
            }
            try #require(f.recorder.currentLease == nil)
        }
    }

    @Test func validHardwareMismatchDoesNotBecomeTransientAndOrdinaryPlanIsUnchanged() throws {
        let hardware = TapFormatPlan.Format(sampleRate: 48_000, channels: 1)
        let output = TapFormatPlan.Format(sampleRate: 44_100, channels: 2)
        let mismatch = TapFormatPlan.Mismatch(hardware: hardware, output: output)
        var waits = 0, rebuilds = 0, selects = 0
        let selector = CaptureBuiltInSelector(defaultIsBuiltIn: { false }, sleep: { _ in waits += 1 })
        var caught: Error?
        do {
            try selector.startFallback(hardwareFormatValid: { true }, select: { selects += 1 },
                rebuild: { rebuilds += 1 }, start: { throw mismatch }, note: { _ in })
        } catch { caught = error }
        try #require(caught as? TapFormatPlan.Mismatch == mismatch)
        try #require(selects == 1 && rebuilds == 0 && waits == 0)
        try #require(!CaptureBuiltInSelector.isFormatNotReady(mismatch))

        var reads = 0
        caught = nil
        do {
            _ = try TapFormatPlan.run(device: .builtIn, formats: {
                reads += 1
                return (.init(sampleRate: 0, channels: 0), output)
            }, align: { Issue.record("Invalid format must not align") }, rebuild: { rebuilds += 1 })
        } catch { caught = error }
        try #require(caught.map(CaptureBuiltInSelector.isFormatNotReady) == true)
        try #require(reads == 2 && rebuilds == 1 && waits == 0)
        let ready = try TapFormatPlan.run(device: .builtIn, formats: { (hardware, hardware) },
            align: { Issue.record("Ready format must not align") }, rebuild: { Issue.record("Ready format must not rebuild") })
        try #require(ready == .ready(aligned: false, rebuilt: false))
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
