import Foundation
import Testing
@testable import DictateCore

/// v1.8 L2/L3/L1 on a fake media clock: the production CaptureFeed (arbitration + health +
/// evidence), BluetoothRecoveryEpisode, HeadsetRestart and OwnedUnitTeardown. No hardware.
/// Every scenario has a RED twin (the failure is caught) and a GREEN twin (healthy audio survives).
@Suite("CaptureHealth")
struct CaptureHealthTests {
    static let chunk = 2_400                       // 100 ms at 24 kHz
    static func tone(_ amplitude: Float = 0.05) -> [Float] {
        (0..<chunk).map { amplitude * Float(sin(Double($0) * 0.13)) + (amplitude > 0 ? amplitude * 0.01 : 0) }
    }
    static let zeros = [Float](repeating: 0, count: chunk)

    /// One 100 ms step: optional built-in and headset buffers starting at `now` (arriving at its
    /// end), then one health tick at the end of the step.
    struct Rig {
        var feed = CaptureFeed()
        var now: TimeInterval = 10
        var keptFrames = 0
        var events: [CaptureBridge.Event] = []
        var fallbackFresh: [Bool] = []
        var refused = 0
        var notes: [String] = []
        var warns: [(TimeInterval, CaptureHealth.Reason)] = []
        var failures: [(TimeInterval, CaptureFailure)] = []
        var stopBuiltin: [TimeInterval] = []
        var signalStarts = 0

        init(bluetooth: Bool = true) {
            feed.start(defaultInput: bluetooth ? .bluetooth : .other, hasBuiltin: bluetooth)
            feed.sourceStarted(.headset, at: 10)
            if bluetooth { feed.sourceStarted(.builtin, at: 10) }
            _ = feed.recordingStarted(at: 10, preRoll: 0)
        }

        mutating func record(_ out: CaptureFeed.Output) {
            keptFrames += out.frames.count
            if let event = out.event { events.append(event) }
            if let fresh = out.fallbackFresh { fallbackFresh.append(fresh) }
            if out.fallbackRefused { refused += 1 }
            if out.headsetSignalStart { signalStarts += 1 }
        }

        mutating func step(builtin: [Float]? = nil, headset: [Float]? = nil) {
            let t = now
            if let builtin { record(feed.accept(builtin, source: .builtin, at: t, arrivedAt: t + 0.1)) }
            if let headset { record(feed.accept(headset, source: .headset, at: t, arrivedAt: t + 0.1)) }
            now = ((t + 0.1) * 1000).rounded() / 1000
            let out = feed.tick(at: now)
            keptFrames += out.frames.count
            notes += out.notes
            if let warn = out.warn { warns.append((now, warn)) }
            if let failure = out.failure { failures.append((now, failure)) }
            if out.stopBuiltin { stopBuiltin.append(now) }
        }
    }

    // MARK: builtin_dies_headset_zeros (10-12 21:33)

    @Test func builtinDiesHeadsetZerosFailsWithin2sOfLastDelivery() throws {
        var rig = Rig()
        for i in 0..<40 { rig.step(builtin: i < 5 ? Self.tone() : nil, headset: Self.zeros) }
        // Last useful delivery: the 5th built-in buffer, arriving at 10.5.
        #expect(rig.failures.count == 1)
        let (at, failure) = try #require(rig.failures.first)
        #expect(at <= 10.5 + CaptureHealth.failAfter + 0.0001)
        #expect(failure.reason == .micDead && failure.health == .staleBuiltin)
        // Real bytes so far (the built-in's speech, then the headset's zeros it fell back to), never 0.
        #expect(failure.framesKept >= 5 * Self.chunk && failure.bytes == 44 + failure.framesKept * 2)
        #expect(failure.lastDeliveryMs == 500 && abs(failure.durationSeconds - (at - 10)) < 0.0001)
        #expect(failure.sources == "builtin:dead,headset:zeros")
        #expect(failure.note.hasPrefix("fail reason=mic_dead health=stale_builtin kept_ms=\(failure.keptMs) last_delivery_ms=500"))
        // The warning is shown at stale detection, well before the end.
        #expect(rig.warns.first?.1 == .staleBuiltin && (rig.warns.first?.0 ?? 99) <= 10.5 + CaptureHealth.staleAfter + 0.1001)
        #expect(rig.notes.contains("health=warn reason=stale_builtin"))
        // No claimed successful fallback onto the dead built-in.
        #expect(!rig.events.contains(.fallback) && rig.fallbackFresh.allSatisfy { !$0 })
        #expect(rig.stopBuiltin.count == 1)
    }

    @Test func builtinKeepsDeliveringSurvivesHeadsetZerosGreen() {
        var rig = Rig()
        for _ in 0..<40 { rig.step(builtin: Self.tone(), headset: Self.zeros) }
        #expect(rig.failures.isEmpty && rig.warns.isEmpty && rig.stopBuiltin.isEmpty)
        #expect(rig.keptFrames == 40 * Self.chunk)                      // complete, nothing duplicated
        #expect(rig.events == [.fallback] && rig.fallbackFresh == [true])
        #expect(rig.feed.bridge.builtinFramesAfterFallback > 0)
    }

    // MARK: both_callbacks_stop / never_first_buffer

    @Test func bothCallbacksStopFailsOnceOnTheClockAlone() {
        var rig = Rig()
        for i in 0..<10 { rig.step(builtin: Self.tone(), headset: i < 10 ? Self.tone() : nil) }
        for _ in 0..<40 { rig.step() }                                   // no buffers at all: ticks only
        #expect(rig.failures.count == 1)
        #expect((rig.failures.first?.0 ?? 99) <= 11.0 + CaptureHealth.failAfter + 0.0001)
    }

    @Test func freshBuffersEvery100msKeepCaptureHealthyGreen() {
        var rig = Rig()
        for _ in 0..<50 { rig.step(builtin: Self.tone(), headset: Self.tone()) }
        #expect(rig.failures.isEmpty && rig.warns.isEmpty)
        #expect(rig.feed.bridge.state == .switched)                     // the headset took over and carries
    }

    @Test func neverFirstBufferFailsByTwoSecondsAfterTheBoundary() {
        var rig = Rig()
        for _ in 0..<40 { rig.step() }
        #expect(rig.failures.count == 1)
        #expect(abs((rig.failures.first?.0 ?? 99) - (10 + CaptureHealth.failAfter)) < 0.0001)
        #expect(rig.failures.first?.1.health == .noInput && rig.failures.first?.1.bytes == 44)
        #expect(rig.warns.first?.1 == .noInput)
    }

    @Test func firstBufferAfter300msIsNotAFailureGreen() {
        var rig = Rig()
        for i in 0..<40 { rig.step(builtin: i >= 3 ? Self.tone() : nil, headset: i >= 3 ? Self.zeros : nil) }
        #expect(rig.failures.isEmpty && rig.warns.isEmpty)
    }

    // MARK: builtin_zeroed_vs_quiet

    @Test func builtinExactZerosWithHeadsetZerosFails() {
        var rig = Rig()
        for i in 0..<40 { rig.step(builtin: i < 5 ? Self.tone() : Self.zeros, headset: Self.zeros) }
        #expect(rig.failures.count == 1 && rig.failures.first?.1.health == .zeros)
        #expect((rig.failures.first?.0 ?? 99) <= 10.5 + CaptureHealth.failAfter + 0.0001)
    }

    @Test func quietSpeechAndATwoSecondPauseAreNeverAFaultGreen() {
        var rig = Rig()
        // 1 s of speech, a 2 s natural pause (quiet but non-zero room noise), then speech again.
        for i in 0..<50 { rig.step(builtin: (10..<30).contains(i) ? Self.tone(0.0005) : Self.tone(), headset: Self.zeros) }
        #expect(rig.failures.isEmpty && rig.warns.isEmpty && rig.stopBuiltin.isEmpty)
        var quiet = Rig()
        for _ in 0..<50 { quiet.step(builtin: Self.tone(0.0003), headset: Self.zeros) }   // −70 dBFS throughout
        #expect(quiet.failures.isEmpty && quiet.warns.isEmpty)
    }

    // MARK: builtin_device_drift

    private final class FakeBuiltin: BuiltinCapture {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onDeviceLost: ((CaptureEpoch) -> Void)?
        var current: UInt32? = 81
        func start(epoch: CaptureEpoch) throws {}
        func stop() {}
        func stop(epoch: CaptureEpoch) {}
        var isDelivering = true
        var currentDeviceID: UInt32? { current }
        var expectedDeviceID: UInt32? = 81
        var lastBufferTime: TimeInterval?
        let backend = "fake"
    }

    @Test func builtinDeviceDriftIsDeadWithinOneTick() {
        let unit = FakeBuiltin()
        unit.current = 154                                               // the headset aggregate (21:33)
        let check = unit.deviceCheck()
        #expect(check == .drift(from: 154) && check?.note == "bridge_device_check=drift from=154 fixed=0")
        var rig = Rig()
        for i in 0..<30 {
            if i == 10, let check, check != .ok { rig.feed.deviceProblem(.builtin, .drift) }
            rig.step(builtin: Self.tone(), headset: Self.tone())
        }
        #expect(rig.stopBuiltin == [11.1])                               // the very next tick
        #expect(rig.notes.contains { $0.hasPrefix("bridge_builtin_lost=1 reason=drift") })
        #expect(rig.failures.isEmpty)                                    // the healthy headset carries
        #expect(rig.feed.health.status(.builtin, at: rig.now) == .dead(.drift))
    }

    @Test func pinnedBuiltinIsNeverMarkedDeadGreen() {
        let unit = FakeBuiltin()
        #expect(unit.deviceCheck() == .ok)
        unit.current = nil
        #expect(unit.deviceCheck() == .drift(from: 0))                  // unreadable is never "ok"
        var rig = Rig()
        for _ in 0..<30 { rig.step(builtin: Self.tone(), headset: Self.zeros) }
        #expect(rig.stopBuiltin.isEmpty && rig.failures.isEmpty)
    }

    // MARK: fallback_requires_fresh_builtin / headset_returns_after_fallback

    @Test func fallbackOntoAStaleBuiltinIsRefused() {
        var rig = Rig()
        for i in 0..<20 { rig.step(builtin: i < 2 ? Self.tone() : nil, headset: Self.zeros) }
        #expect(!rig.events.contains(.fallback))
        #expect(rig.feed.bridge.bridgeSource != "builtin_fallback")
        #expect(rig.feed.bridge.builtinFramesAfterFallback == 0)
    }

    @Test func fallbackOntoABuiltinSilentFor400msIsRefusedRed() {
        // Not dead yet (stale needs 600 ms) but not fresh (300 ms): the 1.5 s fallback decision
        // falls exactly in that gap, so only the freshness gate can refuse it.
        var rig = Rig()
        for i in 0..<15 { rig.step(builtin: i < 11 ? Self.tone() : nil, headset: Self.zeros) }
        #expect(rig.stopBuiltin.isEmpty)                                 // the clock has not called it dead
        #expect(!rig.events.contains(.fallback) && rig.refused == 1 && rig.fallbackFresh == [false])
        #expect(rig.feed.bridge.bridgeSource == "builtin")
    }

    @Test func fallbackOntoAFreshBuiltinIsTakenGreen() {
        var rig = Rig()
        for _ in 0..<20 { rig.step(builtin: Self.tone(), headset: Self.zeros) }
        #expect(rig.events == [.fallback] && rig.fallbackFresh == [true] && rig.refused == 0)
    }

    @Test func recoveredHeadsetRescuesADeadFallbackWithoutDuplicatePCM() {
        var rig = Rig()
        // Built-in carries (fallback at 1.5 s), dies at 2.0 s; the headset returns with signal at 2.0 s.
        for i in 0..<45 { rig.step(builtin: i < 20 ? Self.tone() : nil, headset: i < 20 ? Self.zeros : Self.tone()) }
        #expect(rig.events.contains(.fallback))
        #expect(rig.failures.isEmpty)
        #expect(rig.feed.bridge.state == .switched)                     // .fallback no longer latches
        #expect(rig.signalStarts == 1)
        // Sample-time order: every kept interval starts at or after the previous one's end.
        let intervals = rig.feed.evidence.intervals
        #expect(zip(intervals, intervals.dropFirst()).allSatisfy { $1.start >= $0.end - 0.000001 })
        #expect(rig.keptFrames <= Int((rig.now - 10) * 24_000))         // nothing kept twice
    }

    @Test func headsetBlipShorterThan150msCannotRescueRed() {
        var rig = Rig()
        for i in 0..<45 {
            let headset = i == 20 ? Array(Self.tone().prefix(1_200)) + Array(Self.zeros.prefix(1_200)) : Self.zeros
            rig.step(builtin: i < 20 ? Self.tone() : nil, headset: headset)
        }
        #expect(rig.failures.count == 1 && rig.failures.first?.1.reason == .micDead)
    }

    // MARK: framework_stops_before_notification

    @Test func engineStoppedBeforeItsNotificationKeepsTheBuiltinContinuous() {
        var rig = Rig()
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        for i in 0..<40 {
            // The headset carries from ~0.2 s; AVAudioEngine stops it at 2.0 s; its notification
            // reaches us 300 ms later (the recorder only records it).
            if i == 23 { episode.formatChanged(at: rig.now) }
            rig.step(builtin: Self.tone(), headset: i < 20 ? Self.tone() : nil)
        }
        #expect(rig.failures.isEmpty)
        #expect(rig.notes.contains("bridge_switchback=1 reason=stale_headset"))
        // One continuous interval: the built-in standby replays from where the headset stopped.
        let intervals = rig.feed.evidence.intervals
        #expect(intervals.count == 1)
        #expect(abs((intervals.last?.end ?? 0) - (rig.now - 10)) < 0.11)
        #expect(episode.requests == 0)                                   // a notification is not a restart
    }

    @Test func engineStoppedAndBuiltinGoneFailsRed() {
        var rig = Rig()
        for i in 0..<45 { rig.step(builtin: i < 20 ? Self.tone() : nil, headset: i < 20 ? Self.tone() : nil) }
        #expect(rig.failures.count == 1)
    }

    // MARK: recovery_episode_all_entry_points

    @Test func allFourEntryPointsShareOneRestartPerWindow() {
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        episode.formatChanged(at: 0)
        let first = episode.request(.configuration, at: 0)
        #expect(first == .after(BluetoothRecoveryEpisode.stableFor))    // stable-format debounce
        var later: [BluetoothRecoveryEpisode.Admission] = []
        for (path, time) in [(RecoveryPath.startRetry, 0.1), (.firstBuffer, 0.15), (.restart, 0.3)] {
            later.append(episode.request(path, at: time))
        }
        #expect(later == [.coalesced, .coalesced, .coalesced])
        let began = episode.begin(at: 0.2)
        #expect(began && episode.attempts == 1)
        let during = episode.request(.restart, at: 0.5)
        #expect(during == .coalesced)                                    // still running: no retap→rebuild escape
        episode.settled(.noFrames)
        #expect(episode.request(.startRetry, at: 0.8) == .after(0.7))   // the next window (0 + 1.5), never sooner
        let next = episode.begin(at: 1.5)
        episode.settled(.frames)
        #expect(next && episode.attempts == 2 && episode.lastOutcome == .frames)
    }

    @Test func nonBluetoothRecoveryStaysPromptGreen() {
        var episode = BluetoothRecoveryEpisode(bluetooth: false)
        var admissions: [BluetoothRecoveryEpisode.Admission] = []
        for (path, time) in [(RecoveryPath.configuration, 0.0), (.startRetry, 0.05), (.firstBuffer, 0.1), (.restart, 0.2)] {
            admissions.append(episode.request(path, at: time))
        }
        #expect(admissions == [.now, .now, .now, .now])
    }

    @Test func attemptsAreBoundedPerDictation() {
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        var time = 0.0
        for _ in 0..<BluetoothRecoveryEpisode.maxAttempts {
            _ = episode.request(.restart, at: time)
            _ = episode.begin(at: time)
            episode.settled(.noFrames)
            time += 2
        }
        #expect(episode.request(.restart, at: time) == .exhausted)
    }

    // MARK: restart_request_becomes_obsolete / cancel_during_restart

    @Test func obsoleteQueuedRestartSettlesAsSkippedWithoutAnAttempt() {
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        episode.formatChanged(at: 5)
        guard case .after = episode.request(.restart, at: 5) else { Issue.record("not queued"); return }
        episode.skip()                                                   // healthy signal came back first
        #expect(episode.attempts == 0 && episode.outcomes == [.skipped] && episode.pendingDue == nil)
        let late = episode.begin(at: 5.2)
        #expect(!late)                                                   // nothing left to run
    }

    @Test func currentUnhealthySessionRestartsExactlyOnceGreen() {
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        #expect(episode.request(.restart, at: 5) == .now)
        let began = episode.begin(at: 5)
        let again = episode.begin(at: 5.01)
        #expect(began && !again && episode.attempts == 1)
    }

    @Test func cancelledDictationIgnoresLateFramesAndTicks() {
        var feed = CaptureFeed()
        let old = CaptureEpoch(), current = CaptureEpoch()
        feed.start(defaultInput: .bluetooth, hasBuiltin: true, epoch: old)
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        _ = feed.accept(Self.tone(), source: .builtin, at: 10, epoch: old)
        feed.cancel()
        #expect(feed.tick(at: 13) == CaptureFeed.TickOutput())           // no failure after cancel
        feed.start(defaultInput: .bluetooth, hasBuiltin: true, epoch: current)
        _ = feed.recordingStarted(at: 20, preRoll: 0)
        #expect(feed.accept(Self.tone(), source: .builtin, at: 20, epoch: old).frames.isEmpty)
        #expect(feed.accept(Self.tone(), source: .builtin, at: 20, epoch: current).frames.count == Self.chunk)
    }

    // MARK: partial_start_cleanup / external_client_busy

    private struct StepError: Error {}

    @Test func partialStartCleanupCallsEachStepOnceEvenWhenOneThrows() {
        var teardown = OwnedUnitTeardown()
        teardown.didCreate()                                             // created, start failed later
        var calls: [String] = []
        let errors = teardown.run(stop: { calls.append("stop"); throw StepError() },
                                  uninitialize: { calls.append("uninitialize") },
                                  dispose: { calls.append("dispose") })
        #expect(calls == ["stop", "uninitialize", "dispose"] && errors.count == 1)
        let again = teardown.run(stop: { calls.append("stop") }, uninitialize: { calls.append("uninitialize") },
                                 dispose: { calls.append("dispose") })
        #expect(again.isEmpty && calls.count == 3)                       // idempotent
    }

    @Test func neverCreatedUnitTearsDownNothingGreen() {
        var teardown = OwnedUnitTeardown()
        var calls = 0
        _ = teardown.run(stop: { calls += 1 }, uninitialize: { calls += 1 }, dispose: { calls += 1 })
        #expect(calls == 0)
        teardown.didCreate()
        #expect(teardown.run(stop: { calls += 1 }, uninitialize: { calls += 1 }, dispose: { calls += 1 }).isEmpty)
        #expect(calls == 3)
    }

    @Test func externalClientBusyIsRecordedNotSpunOn() {
        var starts = 0, polls = 0
        let outcome = HeadsetRestart.perform(stop: { true }, isRunningSomewhere: { polls += 1; return true },
                                             sleep: { _ in }, start: { starts += 1 }, startWhenBusy: false, note: { _ in })
        #expect(outcome.externalBusy && !outcome.started && starts == 0)
        #expect(polls <= Int(HeadsetRestart.idlePoll / HeadsetRestart.pollStep) + 2)   // bounded poll
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        _ = episode.request(.restart, at: 0); _ = episode.begin(at: 0)
        episode.settled(.externalBusy)
        #expect(episode.request(.restart, at: 2) == .now)               // at most one more attempt
        _ = episode.begin(at: 2); episode.settled(.externalBusy)
        #expect(episode.request(.restart, at: 4) == .exhausted)          // no spin
        // Our own unit not confirmed stopped: system-wide busy is never called "external".
        let unsure = HeadsetRestart.perform(stop: { false }, isRunningSomewhere: { true }, sleep: { _ in },
                                            start: {}, startWhenBusy: false, note: { _ in })
        #expect(!unsure.externalBusy && unsure.started)
    }

    @Test func idleDevicePermitsTheBoundedAttemptGreen() {
        var starts = 0
        let outcome = HeadsetRestart.perform(stop: { true }, isRunningSomewhere: { false }, sleep: { _ in },
                                             start: { starts += 1 }, startWhenBusy: false, note: { _ in })
        #expect(outcome.started && !outcome.externalBusy && outcome.deviceIdle && starts == 1)
    }

    // MARK: delivery_reenters_recorder (GPT-6 B1)

    /// A stand-in recorder: state lock + ordered delivery, exactly as AudioRecorder uses them.
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        let delivery = OrderedDelivery<[Int16]>()
        var stopped = false
        var callback: (([Int16]) -> Void)?
        func deliver(_ chunk: [Int16]) {
            lock.withLock { if !stopped, let callback { delivery.enqueue(chunk, to: callback) } }
            delivery.drain()
        }
        func stop(remainder: [Int16]) {
            lock.withLock {
                stopped = true
                if let callback { delivery.enqueue(remainder, to: callback) }
            }
            delivery.drain()
        }
    }

    @Test func callbackThatStopsTheRecorderNeitherDeadlocksNorReorders() {
        let recorder = Recorder()
        var received: [Int16] = []
        recorder.callback = { chunk in
            received.append(chunk[0])
            if chunk[0] == 2 { recorder.stop(remainder: [99]) }         // re-enters while delivering
            _ = recorder.lock.withLock { recorder.stopped }             // reads recorder state
        }
        for value in Int16(1)...5 { recorder.deliver([value]) }
        #expect(received == [1, 2, 99])                                  // nothing after the stop's remainder
        #expect(recorder.delivery.lastDelivered == 3)
    }

    @Test func orderedDeliveryKeepsSequenceAcrossThreadsGreen() async {
        let delivery = OrderedDelivery<Int>()
        let lock = NSLock()
        var seen: [Int] = []
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<4 {
                group.addTask {
                    for i in 0..<50 {
                        delivery.enqueue(worker * 1000 + i) { value in lock.withLock { seen.append(value) } }
                        delivery.drain()
                    }
                }
            }
        }
        #expect(seen.count == 200)                                       // ≥ 3 chunks: delivery is really on
        for worker in 0..<4 {
            let mine = seen.filter { $0 / 1000 == worker }
            #expect(mine == mine.sorted())                               // each producer's order kept
        }
        #expect(delivery.lastDelivered == 200 && delivery.pendingCount == 0)
    }

    // MARK: capture evidence (bt-proof inputs)

    @Test func speechSectionsCountSeparatedRunsAndIgnoreClicks() {
        var evidence = CaptureEvidence()
        evidence.start(at: 0)
        var time = 0.0
        func add(_ frames: [Float]) { evidence.append(frames, at: time); time += Double(frames.count) / 24_000 }
        for _ in 0..<3 {                                                  // three 0.5 s phrases, 0.4 s apart
            for _ in 0..<5 { add(Self.tone(0.1)) }
            for _ in 0..<4 { add(Self.tone(0.0005)) }
        }
        #expect(evidence.finalSpeechSections == 3)
        #expect(evidence.intervalsNote == "0-2700")
        var click = CaptureEvidence()
        click.start(at: 0)
        click.append(Array(Self.tone(0.5).prefix(1_200)) + [Float](repeating: 0.0001, count: 1_200), at: 0)
        for i in 1..<30 { click.append(Self.tone(0.0005), at: Double(i) * 0.1) }
        #expect(click.finalSpeechSections == 0)                          // a 50 ms click is not speech
    }

    @Test func intervalsShowGapsAndOverlapsLiterally() {
        var evidence = CaptureEvidence()
        evidence.start(at: 100)
        evidence.append(Self.tone(), at: 100.0)
        evidence.append(Self.tone(), at: 100.1)                          // abutting: merged
        evidence.append(Self.tone(), at: 101.0)                          // a 0.8 s gap
        evidence.append(Self.tone(), at: 101.05)                         // overlapping: kept separate
        #expect(evidence.intervalsNote == "0-200,1000-1100,1050-1150")
        #expect(evidence.framesKept == 4 * Self.chunk)
    }

    // MARK: v1.8 review fixes (Codex high, 2026-10-12)

    @Test func neverFirstBufferFailsEvenBeforeTheBridgeIsConfigured() {
        // #2: the boundary is set, the start (and bridge configuration) is still blocked.
        var feed = CaptureFeed()
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        var failures: [TimeInterval] = [], warns: [CaptureHealth.Reason] = []
        var now = 10.0
        for _ in 0..<40 {
            now = ((now + 0.1) * 1000).rounded() / 1000
            let out = feed.tick(at: now)
            if out.failure != nil { failures.append(now) }
            if let warn = out.warn { warns.append(warn) }
        }
        #expect(failures == [12.0] && warns == [.noInput])
    }

    @Test func aBridgeConfiguredWithinTheDeadlineAndDeliveringIsNotAFailureGreen() {
        var feed = CaptureFeed()
        _ = feed.recordingStarted(at: 10, preRoll: 0)
        var failures = 0
        var now = 10.0
        for step in 0..<40 {
            if step == 5 {                                               // start returns at 10.5
                feed.start(defaultInput: .bluetooth, hasBuiltin: true)
                _ = feed.recordingStarted(at: 10, preRoll: 0)              // the original boundary is kept
            }
            if step >= 5 { _ = feed.accept(Self.tone(), source: .builtin, at: now, arrivedAt: now + 0.1) }
            now = ((now + 0.1) * 1000).rounded() / 1000
            if feed.tick(at: now).failure != nil { failures += 1 }
        }
        #expect(failures == 0)
    }

    @Test func aDeadBuiltinDoesNotHandTheDictationToAZeroHeadset() {
        // #3: death changes liveness only; zeros never become the carried audio.
        var rig = Rig()
        for i in 0..<20 { rig.step(builtin: i < 5 ? Self.tone() : nil, headset: Self.zeros) }
        #expect(rig.feed.bridge.state == .builtinOnly)
        #expect(rig.keptFrames == 5 * Self.chunk)
        var stale = Rig()
        for i in 0..<9 { stale.step(builtin: i < 4 ? Self.tone() : nil, headset: Self.tone()) }   // headset carries
        let failed = stale.feed.headsetFailed(at: stale.now)                // built-in alive but 0.5 s silent
        #expect(failed.event == nil && failed.deferred && failed.frames.isEmpty)
        #expect(stale.feed.bridge.state == .switched)                        // nothing chosen: the clock decides
    }

    @Test func aFreshBuiltinStillTakesOverWhenTheHeadsetEngineFailsGreen() {
        var rig = Rig()
        for _ in 0..<9 { rig.step(builtin: Self.tone(), headset: Self.tone()) }
        let failed = rig.feed.headsetFailed(at: rig.now)
        #expect(failed.event == .switchback && !failed.deferred)
    }

    @Test func aLaterFormatChangeRequeuesTheQueuedRestart() {
        // #4: a notification at 0.19 moves the stable point to 0.39 (bounded by the window).
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        episode.formatChanged(at: 0)
        #expect(episode.request(.configuration, at: 0) == .after(0.2))
        episode.formatChanged(at: 0.19)
        guard case .wait(let more) = episode.beginIfStable(at: 0.2) else { Issue.record("began early"); return }
        #expect(abs(more - 0.19) < 1e-9)
        let early = episode.begin(at: 0.3)
        #expect(!early)                                                    // never before it is due
        #expect(episode.beginIfStable(at: 0.39) == .begun && episode.attempts == 1)
        var storm = BluetoothRecoveryEpisode(bluetooth: true)
        _ = storm.request(.restart, at: 0)
        for step in 1...30 { storm.formatChanged(at: Double(step) * 0.1) }
        guard case .wait(let bounded) = storm.beginIfStable(at: 0.05) else { Issue.record("no wait"); return }
        #expect(bounded <= BluetoothRecoveryEpisode.window)                  // the storm cannot defer it past the window
    }

    @Test func aStableFormatBeginsTheQueuedRestartGreen() {
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        episode.formatChanged(at: 0)
        _ = episode.request(.configuration, at: 0)
        #expect(episode.beginIfStable(at: 0.2) == .begun && episode.attempts == 1)
    }

    /// #5: a refused lifecycle retry touches no hardware.
    private final class AdmittingEngine: CaptureEngine {
        var admission: RecoveryAdmission = .skip
        var starts = 0, rebuilds = 0, admissions: [RecoveryPath] = []
        var isRunning = false
        var isAllocated = false
        func release() { isRunning = false }
        func start(device: MicChoice) throws {
            starts += 1
            if starts == 1 { throw NSError(domain: "test.start", code: 35) }
            isRunning = true
        }
        func stop() -> [Float] { isRunning = false; return [] }
        func rebuild() throws { rebuilds += 1 }
        func recoveryAdmission(_ path: RecoveryPath) -> RecoveryAdmission { admissions.append(path); return admission }
    }

    @Test func refusedStartRetryNeverRebuildsOrRestarts() {
        let engine = AdmittingEngine()
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: CaptureDispatchScheduler())
        #expect(lifecycle.beginRecording(at: 1))
        #expect(engine.admissions == [.startRetry] && engine.rebuilds == 0 && engine.starts == 1)
        lifecycle.end(.cancel)
    }

    @Test func admittedStartRetryRebuildsAndStartsOnceGreen() {
        let engine = AdmittingEngine()
        engine.admission = .proceed(after: 0)
        let lifecycle = CaptureLifecycle(engine: engine, scheduler: CaptureDispatchScheduler())
        #expect(lifecycle.beginRecording(at: 1))
        #expect(engine.admissions == [.startRetry] && engine.rebuilds == 1 && engine.starts == 2 && engine.isRunning)
        lifecycle.end(.cancel)
    }
}
