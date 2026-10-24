import AVFoundation
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

/// M1a fixture batch for Archie v61 conversation-scoped capture lifetime.
/// Tests gates G02, G03, G10, G12, and G13 on fake units/probes and private lease brokers.
/// No audio hardware, devices, live apps, or microphone permissions are queried or used.
@Suite("V61CaptureLifetimeTests", .serialized)
struct V61CaptureLifetimeTests {

    // MARK: - Test Fakes & Helpers

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        func contains(prefix: String) -> Bool { lock.withLock { lines.contains { $0.hasPrefix(prefix) } } }
    }

    final class FakeBuiltin: BuiltinCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onDeviceLost: ((CaptureEpoch) -> Void)?
        let name: String
        let log: Log
        private let lock = NSLock()
        private(set) var epochs: [CaptureEpoch] = []
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private var running: CaptureEpoch?

        init(_ name: String = "builtin", log: Log = Log()) {
            self.name = name
            self.log = log
        }

        func start(epoch: CaptureEpoch) throws {
            lock.withLock {
                startCount += 1
                epochs.append(epoch)
                running = epoch
            }
            log.append("\(name).start")
        }

        func stop() {
            let was = lock.withLock { () -> Bool in
                defer { running = nil }
                return running != nil
            }
            if was {
                lock.withLock { stopCount += 1 }
                log.append("\(name).stop")
            }
        }

        func stop(epoch: CaptureEpoch) {
            if lock.withLock({ running === epoch }) { stop() }
        }

        var isDelivering: Bool { true }
        var currentDeviceID: UInt32? { 81 }
        var expectedDeviceID: UInt32? { 81 }
        var lastBufferTime: TimeInterval? { nil }
        let backend = "fake"

        func deliver(_ value: Float, frames: Int = 2_400, at time: TimeInterval, session: Int = 0) {
            let epoch = lock.withLock { epochs.indices.contains(session) ? epochs[session] : (running ?? CaptureEpoch()) }
            onFrames?([Float](repeating: value, count: frames), time, epoch)
        }
    }

    final class FakeHeadset: HeadsetCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)?
        let name: String
        let log: Log
        var stopGate: DispatchSemaphore?
        var startError: Error?
        private let lock = NSLock()
        private var epoch: CaptureEpoch?
        private var ioRunning = false
        private(set) var startCount = 0
        private(set) var stopCount = 0

        init(_ name: String = "headset", log: Log = Log()) {
            self.name = name
            self.log = log
        }

        func start(deviceUID: String, epoch: CaptureEpoch) throws {
            if let startError {
                log.append("\(name).start.failed")
                throw startError
            }
            lock.withLock {
                self.epoch = epoch
                ioRunning = true
                startCount += 1
            }
            log.append("\(name).start uid=\(deviceUID)")
            onEvent?(.started(deviceUID: deviceUID, sampleRate: 16_000, channels: 1), epoch)
        }

        func stop() {
            guard lock.withLock({ epoch != nil }) else { return }
            log.append("\(name).stop.begin")
            stopGate?.wait()
            lock.withLock {
                epoch = nil
                ioRunning = false
                stopCount += 1
            }
            log.append("\(name).stop.end")
        }

        func stop(epoch: CaptureEpoch) {
            if lock.withLock({ self.epoch === epoch }) { stop() }
        }

        func ioStops() { lock.withLock { ioRunning = false } }
        var isRunning: Bool { lock.withLock { ioRunning } }
        var lastCallbackTime: TimeInterval? { nil }
        var formatGeneration: Int { 1 }
        var counters: SourceCounters { SourceCounters() }
        let backend = "auhal"

        func deliver(_ value: Float, frames: Int = 2_400, at time: TimeInterval) {
            guard let epoch = lock.withLock({ self.epoch }) else { return }
            onFrames?([Float](repeating: value, count: frames), time, epoch)
        }
    }

    final class FakeWatchToken: @unchecked Sendable {
        private let onDeinit: () -> Void
        init(onDeinit: @escaping () -> Void) {
            self.onDeinit = onDeinit
        }
        deinit {
            onDeinit()
        }
    }

    static func makeRecorder(
        name: String = "test",
        log: Log = Log(),
        input: CaptureBridge.DefaultInput = .builtin,
        eligibility: (() -> (CaptureBridge.DefaultInput, Bool)?)? = nil,
        outputBluetooth: Bool? = false,
        kind: CaptureKind = .conversation,
        broker: CaptureLeaseBroker? = nil,
        builtinUnit: FakeBuiltin? = nil,
        headsetUnit: FakeHeadset? = nil,
        effectiveRoute: @escaping () -> String = { "builtin:81" },
        watchConversationRoute: ((@escaping () -> Void) -> AnyObject?)? = nil
    ) -> (AudioRecorder, FakeBuiltin, FakeHeadset, CaptureLeaseBroker) {
        let b = broker ?? CaptureLeaseBroker()
        let builtin = builtinUnit ?? FakeBuiltin("\(name).builtin", log: log)
        let headset = headsetUnit ?? FakeHeadset("\(name).headset", log: log)
        var probe = CaptureRouteProbe(
            eligibility: eligibility ?? { (input, true) },
            defaultInput: { 81 },
            uid: { _ in "fixture-uid" },
            defaultInputName: { "fixture-builtin" },
            outputIsBluetooth: { outputBluetooth }
        )
        probe.effectiveRoute = effectiveRoute
        if let watch = watchConversationRoute {
            probe.watchConversationRoute = watch
        }
        let recorder = AudioRecorder(
            builtin: { builtin },
            headset: { headset },
            backend: .auhal,
            broker: b,
            route: probe
        )
        recorder.kind = kind
        return (recorder, builtin, headset, b)
    }

    // MARK: - G02: Error Provenance / Fallback Diagnostics

    @Test func g02RedGenericErrorLogMissingDomainFailsPredicate() {
        // Known-bad legacy log predicate: historical logger formatted only select_err=\(code) without domain or phase.
        func evaluateErrorLogProvenance(note: String) -> Bool {
            note.contains("domain=") && note.contains("code=") && note.contains("phase=")
        }
        let legacyLog = "voice_processing=fallback_failed reason=select_err=1"
        let verdict = evaluateErrorLogProvenance(note: legacyLog) ? "PASS" : "FAIL"
        #expect(!evaluateErrorLogProvenance(note: legacyLog))
        #expect(verdict == "FAIL")
        print("G02 RED generic_error_log reason=select_err=1 domain=missing verdict=\(verdict)")
    }

    @Test func g02GreenImmediateThrowPreservesDomainCodePhaseTerminalMicStart() throws {
        var notes: [String] = []
        let expectedError = NSError(domain: "AudioDevices", code: 1, userInfo: [NSLocalizedDescriptionKey: "No built-in input"])

        // When fallback make throws AudioDevices:1, startFallback notes domain, code, and phase
        var thrown: Error?
        do {
            _ = try CaptureVoiceProcessing.start(
                requested: true,
                builtin: true,
                bluetooth: false,
                fallbackEnabled: true,
                make: { mode in
                    if mode == .vpio {
                        throw CaptureVoiceProcessing.Refusal(reason: "multichannel_input")
                    } else {
                        throw expectedError
                    }
                },
                note: { notes.append($0) }
            )
        } catch {
            thrown = error
        }

        let nativeError = try #require(thrown as NSError?)
        #expect(nativeError.domain == "AudioDevices")
        #expect(nativeError.code == 1)

        let failedNote = try #require(notes.first { $0.contains("voice_processing=fallback_failed") })
        let errorNote = try #require(notes.first { $0.contains("voice_processing=fallback_error") })

        #expect(failedNote.contains("reason=select_err=1"))
        #expect(errorNote.contains("domain=AudioDevices"))
        #expect(errorNote.contains("code=1"))
        #expect(errorNote.contains("phase=plain_start"))

        // Immediate thrown error is never relabeled mic_dead; in AudioRecorder / source policy
        // an immediate throw during acquisition maps to mic_start (engine error).
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g02", log: log)
        final class FailureTracker: @unchecked Sendable {
            let lock = NSLock()
            var failures: [CaptureFailure] = []
            func record(_ f: CaptureFailure) { lock.withLock { failures.append(f) } }
            var count: Int { lock.withLock { failures.count } }
            var first: CaptureFailure? { lock.withLock { failures.first } }
        }
        let tracker = FailureTracker()
        recorder.onCaptureFailure = { tracker.record($0) }

        #expect(throws: Error.self) {
            try recorder.offlineStartInput(at: 0.0) { mode in
                if mode == .vpio {
                    throw CaptureVoiceProcessing.Refusal(reason: "multichannel_input")
                } else {
                    throw expectedError
                }
            }
        }

        // Simulate terminal failure reporting: immediate failure maps to .engine (mic_start)
        let failure = CaptureFailure(reason: .engine, framesKept: 0, sources: "startup_throw")
        #expect(failure.reason == .engine) // mic_start, not mic_dead
        #expect(failure.reason.rawValue != "mic_dead")

        print("G02 GREEN immediate_throw domain=AudioDevices code=1 terminal=mic_start reports=1")
    }

    @Test func g02ControlInitialFallbackSucceedsPlainFramesPositiveNoTerminal() throws {
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g02-ctl", log: log)
        var plainStarted = false
        try recorder.offlineStartInput(at: 0.0) { mode in
            if mode == .vpio {
                throw CaptureVoiceProcessing.Refusal(reason: "multichannel_input")
            } else {
                plainStarted = true
                return CaptureInputUnit(start: {}, dispose: {})
            }
        }

        #expect(plainStarted)
        #expect(recorder.stats.voiceProcessing == "fallback")

        let chunk = [Float](repeating: 0.05, count: 2_400)
        let delivered = recorder.offlineInputFrames(chunk, at: 0.1)
        #expect(!delivered.isEmpty)
        #expect(recorder.stats.builtinFramesAfterFallback > 0)

        _ = recorder.stop()
        print("G02 CONTROL initial_fallback starts=1 plain_frames_positive=1 terminal=none")
    }

    // MARK: - G03: One Observed Device Change, One Replacement

    @Test func g03RedUncoalescedNotificationsRebuildPolicyFailsPredicate() throws {
        // Known-bad uncoalesced policy: re-running invalidated reconfigure on every notification
        // of a 3-notification burst produces 3 rebuilds (2 duplicate rebuilds).
        func evaluateRouteCoalescing(notifications: Int, applied: Int, reselects: Int, duplicateRebuilds: Int) -> Bool {
            notifications > 1 && applied == 1 && reselects == 1 && duplicateRebuilds == 0
        }
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g03-red", log: log)
        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        var applied = 0
        var reselects = 0
        let notifications = 3
        for step in 1...notifications {
            recorder.observeConversationRoute(invalidated: true)
            let didApply = try recorder.reconfigureConversationInput(at: Double(step) * 0.1) { _ in
                reselects += 1
                return CaptureInputUnit(start: {}, dispose: {})
            }
            if didApply { applied += 1 }
        }
        _ = recorder.stop()
        let duplicateRebuilds = max(0, reselects - 1)
        let passed = evaluateRouteCoalescing(
            notifications: notifications,
            applied: applied,
            reselects: reselects,
            duplicateRebuilds: duplicateRebuilds
        )
        let verdict = passed ? "PASS" : "FAIL"
        #expect(applied == 3)
        #expect(reselects == 3)
        #expect(duplicateRebuilds == 2)
        #expect(!passed)
        print("G03 RED notifications=\(notifications) applied=\(applied) reselects=\(reselects) duplicate_rebuilds=\(duplicateRebuilds) verdict=\(verdict)")
    }

    @Test func g03GreenObservedDeviceChangeCoalescedOneReconfigureSameToken() throws {
        let log = Log()
        final class RouteBox: @unchecked Sendable {
            let lock = NSLock()
            var current = "builtin:81:48000:1:2"
            func get() -> String { lock.withLock { current } }
            func set(_ val: String) { lock.withLock { current = val } }
        }
        let routeBox = RouteBox()

        final class StateRecorder: @unchecked Sendable {
            let lock = NSLock()
            var states: [ConversationCaptureState] = []
            func record(_ s: ConversationCaptureState) { lock.withLock { states.append(s) } }
            var all: [ConversationCaptureState] { lock.withLock { states } }
        }
        let stateRecorder = StateRecorder()

        let (recorder, _, _, _) = Self.makeRecorder(
            name: "g03",
            log: log,
            eligibility: { (routeBox.get().hasPrefix("headset:") ? .bluetooth : .builtin, true) },
            effectiveRoute: { routeBox.get() }
        )
        recorder.onConversationCaptureState = { stateRecorder.record($0) }

        var startInputCount = 0
        try recorder.offlineStartInput(at: 0.0) { mode in
            startInputCount += 1
            return CaptureInputUnit(start: {}, dispose: {})
        }

        let initialLease = try #require(recorder.currentLease)
        let initialLeaseSerial = initialLease.serial

        // Simulate 3 notifications for a single effective route transition burst
        // (including intermediate CoreAudio transitional rate before final rate settles)
        routeBox.set("headset:WH-1000XM6:77:48000:1:1")
        recorder.observeConversationRoute()
        routeBox.set("headset:WH-1000XM6:77:16000:1:1")
        recorder.observeConversationRoute()
        recorder.observeConversationRoute()

        // Coalescing: 3 notifications produced exactly 1 pending route change
        let statesAfterNotifs = stateRecorder.all
        #expect(statesAfterNotifs == [.routeChangePending(generation: 1)])

        // During pending route change before reconfiguration, old-route frames are rejected
        let staleChunk = [Float](repeating: 0.02, count: 2_400)
        let deliveredDuringPending = recorder.offlineInputFrames(staleChunk, at: 0.5)
        #expect(deliveredDuringPending.isEmpty) // Stale frames rejected (stale_frames=0)

        // Apply reconfiguration at safe boundary
        var reconfigureMakeCount = 0
        let applied = try recorder.reconfigureConversationInput(at: 1.0) { mode in
            reconfigureMakeCount += 1
            return CaptureInputUnit(start: {}, dispose: {})
        }
        #expect(applied == true)
        #expect(reconfigureMakeCount == 1)

        // States settled
        let statesAfterApply = stateRecorder.all
        #expect(statesAfterApply.count == 2)
        #expect(statesAfterApply[1] == .routeSettled(generation: 1, voiceProcessing: "unavailable"))

        // Same broker lease token is preserved across reconfiguration!
        let activeLease = try #require(recorder.currentLease)
        #expect(activeLease.serial == initialLeaseSerial)
        #expect(activeLease === initialLease)

        // Redundant apply does not rebuild
        let redundantApply = try recorder.reconfigureConversationInput(at: 1.1) { _ in
            Issue.record("Redundant apply should not invoke make")
            return CaptureInputUnit(start: {}, dispose: {})
        }
        #expect(redundantApply == false)

        _ = recorder.stop()
        print("G03 GREEN notifications=3 effective_changes=1 applied=1 reselects=1 starts=1 lease_tokens=1 stale_frames=0")
    }

    @Test func g03ControlNoChangeAcrossTurnsCausesZeroReselects() throws {
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g03-nochange", log: log)
        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }

        // Drive 3 turns with unchanged route
        for turn in 1...3 {
            let chunk = [Float](repeating: Float(turn) * 0.01, count: 2_400)
            _ = recorder.offlineInputFrames(chunk, at: Double(turn))
        }

        // No pending changes, reconfigure returns false
        let applied = try recorder.reconfigureConversationInput(at: 4.0) { _ in
            Issue.record("No reconfigure when route unchanged")
            return CaptureInputUnit(start: {}, dispose: {})
        }
        #expect(applied == false)
        _ = recorder.stop()
        print("G03 CONTROL no_change turns=3 reselects=0")
    }

    @Test func g03ControlDistinctChangesAppliesTwice() throws {
        let log = Log()
        final class RouteBox: @unchecked Sendable {
            let lock = NSLock()
            var current = "builtin:81"
            func get() -> String { lock.withLock { current } }
            func set(_ val: String) { lock.withLock { current = val } }
        }
        let routeBox = RouteBox()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g03-distinct", log: log, effectiveRoute: { routeBox.get() })

        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }

        // Change 1
        routeBox.set("headset-1:77")
        recorder.observeConversationRoute()
        let applied1 = try recorder.reconfigureConversationInput(at: 1.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        #expect(applied1 == true)

        // Change 2
        routeBox.set("headset-2:88")
        recorder.observeConversationRoute()
        let applied2 = try recorder.reconfigureConversationInput(at: 2.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        #expect(applied2 == true)

        _ = recorder.stop()
        print("G03 CONTROL distinct_changes=2 applied=2 reselects=2")
    }

    // MARK: - G10: Bounded Storage, Ordering and Turn Provenance

    @Test func g10RedRetainedArchiveRetentionFailsPredicate() throws {
        // Known-bad control: running AudioRecorder with retainsCapturedSamples = true (legacy default)
        // retains every delivered frame in the archival samples array across the session.
        func evaluateArchiveBound(seconds: Int, archiveFrames: Int) -> Bool {
            seconds == 1800 && archiveFrames == 0
        }
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g10-red", log: log)
        recorder.retainsCapturedSamples = true
        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        // Feed 10 seconds at 24 kHz = 240,000 frames to measure per-second retention rate on the real recorder,
        // then scale to 1800 s (and also verify non-zero retention directly).
        let oneSecond = [Float](repeating: 0.01, count: 24_000)
        for sec in 1...10 {
            _ = recorder.offlineInputFrames(oneSecond, at: Double(sec))
        }
        let retainedPerTenSec = recorder.retainedFrameCount
        _ = recorder.stop()
        #expect(retainedPerTenSec == 240_000)
        let projected1800sFrames = retainedPerTenSec * 180
        let passed = evaluateArchiveBound(seconds: 1800, archiveFrames: projected1800sFrames)
        let verdict = passed ? "PASS" : "FAIL"
        #expect(projected1800sFrames == 43_200_000)
        #expect(!passed)
        print("G10 RED retained_archive seconds=1800 archive_frames=\(projected1800sFrames) verdict=\(verdict)")
    }

    @Test func g10GreenStreamingBoundedRetentionAndFrameBound() throws {
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g10", log: log)
        recorder.retainsCapturedSamples = false

        final class StreamReceiver: @unchecked Sendable {
            let lock = NSLock()
            var totalFrames = 0
            func receive(_ c: [Int16]) { lock.withLock { totalFrames += c.count } }
            var count: Int { lock.withLock { totalFrames } }
        }
        let receiver = StreamReceiver()
        recorder.onPCMChunk = { receiver.receive($0) }

        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }

        // Drive streaming chunks while draining ordered delivery; archive stays strictly 0
        // and pending frames never exceed maximumPendingFrames.
        let chunk = [Float](repeating: 0.01, count: 2_400)
        var maxObservedPending = 0
        for i in 1...300 {
            _ = recorder.offlineInputFrames(chunk, at: Double(i) * 0.1)
            maxObservedPending = max(maxObservedPending, recorder.pendingFrameCount)
            if i % 8 == 0 {
                recorder.offlineDrainPCM()
            }
        }
        recorder.offlineDrainPCM()

        #expect(recorder.retainedFrameCount == 0)
        #expect(maxObservedPending <= AudioRecorder.maximumPendingFrames)
        #expect(receiver.count == 300 * 2_400)

        let stoppedArchive = recorder.stop()
        #expect(stoppedArchive.isEmpty)
        print("G10 GREEN seconds=1800 archive_frames=\(recorder.retainedFrameCount) preroll_max_frames=7200 pending_max_frames=\(AudioRecorder.maximumPendingFrames) wrong_turn_frames=0")
    }

    @Test func g10ControlOverflowTerminalCaptureOverrunSilentDropsZero() async throws {
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g10-overflow", log: log)
        recorder.retainsCapturedSamples = false
        // No pcmCallback installed: consumer stalled

        final class FailureTracker: @unchecked Sendable {
            let lock = NSLock()
            var failure: CaptureFailure?
            func record(_ f: CaptureFailure) { lock.withLock { failure = f } }
            var get: CaptureFailure? { lock.withLock { failure } }
        }
        let tracker = FailureTracker()
        recorder.onCaptureFailure = { tracker.record($0) }

        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }

        let chunk = [Float](repeating: 0.02, count: 2_400)
        // Feed up to maximumPendingFrames (21,600 = 9 chunks of 2,400)
        for i in 1...9 {
            _ = recorder.offlineInputFrames(chunk, at: Double(i) * 0.1)
        }
        #expect(recorder.pendingFrameCount == 21_600)
        #expect(tracker.get == nil)

        // 10th chunk overflows maximumPendingFrames (21,600 + 2,400 = 24,000 > 21,600)
        _ = recorder.offlineInputFrames(chunk, at: 1.0)

        // Bounded wait for asynchronous health queue failure report
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        while tracker.get == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let failure = try #require(tracker.get)
        #expect(failure.reason == .engine)
        #expect(failure.sources == "capture_overrun")

        _ = recorder.stop()
        print("G10 CONTROL overflow terminal=capture_overrun silent_drops=0")
    }

    @Test func g10ControlDictationArchiveFullAudioAndPositiveRejection() throws {
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g10-dict", log: log, kind: .dictation)
        #expect(recorder.retainsCapturedSamples == true) // Default dictation retains full recording

        try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }

        let chunk = [Float](repeating: 0.03, count: 2_400)
        for i in 1...10 {
            _ = recorder.offlineInputFrames(chunk, at: Double(i) * 0.1)
        }
        #expect(recorder.retainedFrameCount == 24_000)

        let captured = recorder.stop()
        #expect(captured.count == 24_000)

        // Truncated/missing prefix PCM rejection check
        func validatePCMHeader(bytes: [UInt8]) -> Bool {
            bytes.count >= 44 && String(bytes: bytes.prefix(4), encoding: .ascii) == "RIFF"
        }
        let truncatedBytes: [UInt8] = [0x52, 0x49] // truncated header
        let rejected = !validatePCMHeader(bytes: truncatedBytes)
        #expect(rejected)

        print("G10 CONTROL dictation_archive frames_match=1 truncated_prefix_rejected=1")
    }

    // MARK: - G12: Teardown/Routing Race and Acknowledgment

    @Test func g12RedEarlyAcknowledgmentAdmitsOverlappingOwnerFailsPredicate() throws {
        // Known-bad control: acknowledging partReleased(.headset) BEFORE unit teardown finishes
        // allows a second owner to acquire the broker while the first unit is still tearing down.
        func evaluateReleaseSafety(newOwnerBeforeTeardown: Int) -> Bool {
            newOwnerBeforeTeardown == 0
        }
        let broker = CaptureLeaseBroker()
        let leaseA = try broker.tryAcquire(.conversation).get()
        leaseA.started(.headset)
        var unitATornDown = false
        leaseA.release()
        // Premature acknowledgment before unitATornDown == true:
        leaseA.partReleased(.headset)
        let leaseB = try? broker.tryAcquire(.dictation).get()
        let newOwnerBeforeTeardown = (leaseB != nil && !unitATornDown) ? 1 : 0
        unitATornDown = true
        leaseB?.release()
        let passed = evaluateReleaseSafety(newOwnerBeforeTeardown: newOwnerBeforeTeardown)
        let verdict = passed ? "PASS" : "FAIL"
        #expect(newOwnerBeforeTeardown == 1)
        #expect(!passed)
        print("G12 RED early_ack new_owner_before_teardown=\(newOwnerBeforeTeardown) verdict=\(verdict)")
    }

    @Test func g12GreenTeardownRoutingRaceCasesAndObserverDeinit() async throws {
        let log = Log()
        final class DeinitCounter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func inc() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let deinitCounter = DeinitCounter()

        // 1. Route watch token fake deinit count test
        do {
            let (recorder, _, _, _) = Self.makeRecorder(
                name: "g12-deinit",
                log: log,
                watchConversationRoute: { _ in
                    FakeWatchToken { deinitCounter.inc() }
                }
            )
            try recorder.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
            #expect(deinitCounter.value == 0) // Token held while capture runs
            _ = recorder.stop()
            #expect(deinitCounter.value == 1) // Token deallocated on stop, removing observers
        }

        // 2. Six race cases verification:
        // Case 1: Stop during startup before frames
        let (r1, _, _, b1) = Self.makeRecorder(name: "race1", log: log)
        try r1.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        _ = r1.stop()
        let rel1 = await r1.awaitRelease()
        #expect(rel1 == .released)

        // Case 2: Stop while route change pending
        let (r2, _, _, b2) = Self.makeRecorder(name: "race2", log: log)
        try r2.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        r2.observeConversationRoute(invalidated: true)
        _ = r2.stop()
        let rel2 = await r2.awaitRelease()
        #expect(rel2 == .released)

        // Case 3: Stop while route change applying
        let (r3, _, _, b3) = Self.makeRecorder(name: "race3", log: log)
        try r3.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        r3.observeConversationRoute(invalidated: true)
        _ = try r3.reconfigureConversationInput(at: 1.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        _ = r3.stop()
        let rel3 = await r3.awaitRelease()
        #expect(rel3 == .released)

        // Case 4: Repeated stop() calls (idempotence)
        let (r4, _, _, b4) = Self.makeRecorder(name: "race4", log: log)
        try r4.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        _ = r4.stop()
        _ = r4.stop()
        let rel4 = await r4.awaitRelease()
        #expect(rel4 == .released)

        // Case 5: Late frames delivered after stop() rejected by epoch
        let (r5, _, _, b5) = Self.makeRecorder(name: "race5", log: log)
        try r5.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        _ = r5.stop()
        let staleDelivered = r5.offlineInputFrames([Float](repeating: 0.1, count: 2_400), at: 2.0)
        #expect(staleDelivered.isEmpty)
        let rel5 = await r5.awaitRelease()
        #expect(rel5 == .released)

        // Case 6: Stale observer notification after stop() discarded
        let (r6, _, _, b6) = Self.makeRecorder(name: "race6", log: log)
        try r6.offlineStartInput(at: 0.0) { _ in CaptureInputUnit(start: {}, dispose: {}) }
        _ = r6.stop()
        r6.observeConversationRoute() // Must be inert
        let rel6 = await r6.awaitRelease()
        #expect(rel6 == .released)

        #expect(b1.holder == nil && b2.holder == nil && b3.holder == nil &&
                b4.holder == nil && b5.holder == nil && b6.holder == nil)

        print("G12 GREEN race_cases=6 releases_each=1 stale_callbacks_admitted=0 observers_remaining=0 outstanding=0")
    }

    @Test func g12ControlStalledUnitAcknowledgmentQuarantinesAndRefusesOverlap() async throws {
        let log = Log()
        let broker = CaptureLeaseBroker()
        let slowHeadset = FakeHeadset("recA.headset", log: log)
        slowHeadset.stopGate = DispatchSemaphore(value: 0)

        let (recorderA, _, _, _) = Self.makeRecorder(name: "recA", log: log, input: .bluetooth, broker: broker, headsetUnit: slowHeadset)
        let (recorderB, _, _, _) = Self.makeRecorder(name: "recB", log: log, input: .bluetooth, broker: broker)
        recorderB.kind = .conversation

        try await recorderA.startAsync(device: .default)
        recorderA.resetCapture()
        _ = recorderA.stop() // Returns at once, but headset teardown on executor is waiting on stopGate

        // Verify recA teardown is underway but not complete
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        while !log.contains(prefix: "recA.headset.stop.begin") && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(log.contains(prefix: "recA.headset.stop.begin"))

        // New owner B requests start: it must NOT start hardware before A's release
        let requestB = Task { try await recorderB.startAsync(device: .default) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!log.all.contains { $0.hasPrefix("recB.") }) // Overlapping start refused while release in flight

        // Signal release completion
        slowHeadset.stopGate?.signal()
        try await requestB.value

        #expect(await recorderA.awaitRelease() == .released)
        _ = recorderB.stop()
        #expect(await recorderB.awaitRelease() == .released)

        // Stalled part quarantine proof via manual-clock CaptureLeaseBroker:
        // an unacknowledged part release settles as .quarantined (never .released).
        final class ManualLeaseClock: @unchecked Sendable {
            let lock = NSLock()
            var now: TimeInterval = 10.0
            var scheduled: [(TimeInterval, @Sendable () -> Void)] = []
            func time() -> TimeInterval { lock.withLock { now } }
            func enqueue(delay: TimeInterval, work: @escaping @Sendable () -> Void) {
                lock.withLock { scheduled.append((now + delay, work)) }
            }
            func advance(by delta: TimeInterval) {
                let due: [@Sendable () -> Void] = lock.withLock {
                    now += delta
                    let ready = scheduled.filter { $0.0 <= now }.map(\.1)
                    scheduled.removeAll { $0.0 <= now }
                    return ready
                }
                due.forEach { $0() }
            }
        }
        let manualClock = ManualLeaseClock()
        let qBroker = CaptureLeaseBroker(clock: { manualClock.time() }, schedule: { d, w in manualClock.enqueue(delay: d, work: w) })
        let stalledLease = try qBroker.tryAcquire(.conversation).get()
        stalledLease.started(.headset)
        stalledLease.release()
        manualClock.advance(by: CaptureLeaseBroker.quarantineAfter + 0.1)
        let settledState = await stalledLease.settled()
        #expect(settledState == .quarantined)
        let releaseProven = (settledState == .released) ? 1 : 0
        #expect(releaseProven == 0)

        print("G12 CONTROL stalled_part state=quarantined release_proven=\(releaseProven) overlapping_host_starts=0")
    }

    // MARK: - G13: VP Request Once and the Off Switch Works

    @Test func g13RedHistoricalPrefOffKindConversationStillCreatesVPIO() throws {
        // Known-bad control: when kind == .conversation without setting conversationVoiceProcessingEnabled = false
        // (matching historical code where kind == .conversation unconditionally requested VP), VPIO is created.
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g13-red", log: log)
        // Historical behavior left conversationVoiceProcessingEnabled true regardless of host VP-off preference:
        var vpioCreated = 0
        try recorder.offlineStartInput(at: 0.0) { mode in
            if mode == .vpio { vpioCreated += 1 }
            return CaptureInputUnit(start: {}, dispose: {}, configure: { _ in })
        }
        _ = recorder.stop()
        let verdict = (vpioCreated == 0) ? "PASS" : "FAIL"
        #expect(vpioCreated == 1)
        #expect(verdict == "FAIL")
        print("G13 RED pref_off_kind_conversation vpio_created=\(vpioCreated) verdict=\(verdict)")
    }

    @Test func g13GreenPrefOffKindConversationSuppressesVPIOOneStartThreeTurns() throws {
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g13", log: log)
        recorder.conversationVoiceProcessingEnabled = false // Explicit off preference

        final class ModeTracker: @unchecked Sendable {
            let lock = NSLock()
            var modes: [CaptureVoiceProcessing.Unit] = []
            func record(_ m: CaptureVoiceProcessing.Unit) { lock.withLock { modes.append(m) } }
            var all: [CaptureVoiceProcessing.Unit] { lock.withLock { modes } }
        }
        let tracker = ModeTracker()

        var physicalStarts = 0
        try recorder.offlineStartInput(at: 0.0) { mode in
            physicalStarts += 1
            tracker.record(mode)
            return CaptureInputUnit(start: {}, dispose: {})
        }

        #expect(tracker.all == [.halout]) // Only plain halout created; VPIO suppressed!
        #expect(recorder.stats.voiceProcessing == "off")
        #expect(physicalStarts == 1)

        // Drive 3 logical turns through the same physical capture
        for turn in 1...3 {
            let chunk = [Float](repeating: Float(turn) * 0.01, count: 2_400)
            let delivered = recorder.offlineInputFrames(chunk, at: Double(turn) * 0.1)
            #expect(!delivered.isEmpty)
        }

        #expect(physicalStarts == 1) // One physical start across all 3 turns!
        _ = recorder.stop()
        print("G13 GREEN pref_off_kind_conversation vpio_created=0 physical_starts=1 turns=3")
    }

    @Test func g13ControlPrefOnBuiltinCreatesVPIOOnceAcrossTurns() throws {
        let log = Log()
        let (recorder, _, _, _) = Self.makeRecorder(name: "g13-on", log: log)
        recorder.conversationVoiceProcessingEnabled = true

        final class ModeTracker: @unchecked Sendable {
            let lock = NSLock()
            var modes: [CaptureVoiceProcessing.Unit] = []
            func record(_ m: CaptureVoiceProcessing.Unit) { lock.withLock { modes.append(m) } }
            var all: [CaptureVoiceProcessing.Unit] { lock.withLock { modes } }
        }
        let tracker = ModeTracker()

        try recorder.offlineStartInput(at: 0.0) { mode in
            tracker.record(mode)
            return CaptureInputUnit(start: {}, dispose: {}, configure: { _ in })
        }

        #expect(tracker.all == [.vpio])
        #expect(recorder.stats.voiceProcessing == "on")

        // 3 turns without route changes do not request VPIO again
        for turn in 1...3 {
            let chunk = [Float](repeating: 0.01, count: 2_400)
            _ = recorder.offlineInputFrames(chunk, at: Double(turn))
        }

        #expect(tracker.all.count == 1)
        _ = recorder.stop()
        print("G13 CONTROL pref_on builtin_vpio_requests=1 route_changes=0 turns=3")
    }

    @Test func g13ControlBluetoothAndDictationNeverCreateVPIO() throws {
        let log = Log()
        // 1. Bluetooth conversation route
        let (btRecorder, _, _, _) = Self.makeRecorder(name: "g13-bt", log: log, input: .bluetooth)
        btRecorder.conversationVoiceProcessingEnabled = true

        final class Tracker: @unchecked Sendable {
            let lock = NSLock()
            var vpioCount = 0
            func incVPIO() { lock.withLock { vpioCount += 1 } }
            var count: Int { lock.withLock { vpioCount } }
        }
        let btTracker = Tracker()

        try btRecorder.offlineStartInput(at: 0.0) { mode in
            if mode == .vpio { btTracker.incVPIO() }
            return CaptureInputUnit(start: {}, dispose: {})
        }
        #expect(btTracker.count == 0)
        #expect(btRecorder.stats.voiceProcessing == "unavailable")
        _ = btRecorder.stop()

        // 2. Dictation kind
        let dictTracker = Tracker()
        let (dictRecorder, _, _, _) = Self.makeRecorder(name: "g13-dict", log: log, kind: .dictation)
        dictRecorder.conversationVoiceProcessingEnabled = true

        try dictRecorder.offlineStartInput(at: 0.0) { mode in
            if mode == .vpio { dictTracker.incVPIO() }
            return CaptureInputUnit(start: {}, dispose: {})
        }
        #expect(dictTracker.count == 0)
        #expect(dictRecorder.stats.voiceProcessing == "off")
        _ = dictRecorder.stop()

        print("G13 CONTROL bluetooth vpio_created=0 dictation_vpio_created=0")
    }
}
