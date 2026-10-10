import Foundation
import Testing
@testable import DictateCore

/// v1.7 H2–H4 on fakes: no audio hardware is opened.
@Suite("HeadsetRecovery")
struct HeadsetRecoveryTests {
    // MARK: H2 — the restart sequence

    private final class FakeHeadset {
        var log: [String] = []
        var clock: TimeInterval = 0
        /// The Bluetooth input keeps running somewhere until this time (another client, coreaudiod teardown).
        var busyUntil: TimeInterval = 0
        var unreadable = false
        func stop() { log.append("stop@\(ms)") }
        func running() -> Bool? { unreadable ? nil : clock < busyUntil }
        func sleep(_ s: TimeInterval) { clock += s }
        func start() { log.append("start@\(ms)") }
        var ms: Int { Int((clock * 1000).rounded()) }
    }

    @Test func restartStopsWaitsForIdleThenSettlesAndStartsOnce() {
        let fake = FakeHeadset()
        fake.busyUntil = 0.1
        let outcome = HeadsetRestart.perform(stop: fake.stop, isRunningSomewhere: fake.running,
                                             sleep: fake.sleep, start: fake.start, note: { _ in })
        #expect(fake.log == ["stop@0", "start@250"])                  // idle at 100 ms + 150 ms settle
        #expect(outcome == .init(waitedMs: 250, deviceIdle: true, started: true))
    }

    @Test func restartPollIsBoundedAt400ms() {
        let fake = FakeHeadset()
        fake.busyUntil = 10
        let outcome = HeadsetRestart.perform(stop: fake.stop, isRunningSomewhere: fake.running,
                                             sleep: fake.sleep, start: fake.start, note: { _ in })
        #expect(fake.log == ["stop@0", "start@550"])
        #expect(!outcome.deviceIdle && outcome.started)
        let unreadable = FakeHeadset()
        unreadable.unreadable = true
        _ = HeadsetRestart.perform(stop: unreadable.stop, isRunningSomewhere: unreadable.running,
                                   sleep: unreadable.sleep, start: unreadable.start, note: { _ in })
        #expect(unreadable.log == ["stop@0", "start@550"])
    }

    @Test func failedRestartIsNotedNotRetried() {
        let fake = FakeHeadset()
        var notes = 0, starts = 0
        let outcome = HeadsetRestart.perform(stop: fake.stop, isRunningSomewhere: fake.running, sleep: fake.sleep,
                                             start: { starts += 1; throw CancellationError() }, note: { _ in notes += 1 })
        #expect(!outcome.started && starts == 1 && notes == 1)
    }

    // MARK: H3 — the bridge child stays on the built-in device (fake AUHAL)

    private final class FakeAUHAL {
        var device: UInt32
        /// AVAudioEngine re-binds to the default device on a configuration change.
        var refusesWrites = false
        init(_ device: UInt32) { self.device = device }
        func read() throws -> UInt32 { device }
        func write(_ id: UInt32) throws {
            if refusesWrites { throw NSError(domain: NSOSStatusErrorDomain, code: -10851) }
            device = id
        }
    }

    @Test func pinnedChildReportsOk() {
        let unit = FakeAUHAL(81)
        #expect(BuiltinPin.enforce(expected: 81, read: unit.read, write: unit.write) == .ok)
        #expect(BuiltinPin.Check.ok.note == "bridge_device_check=ok")
    }

    @Test func driftedChildIsMovedBackToTheBuiltin() {
        let unit = FakeAUHAL(152)                                        // 03:12:14.674 "from 81 to 152"
        let check = BuiltinPin.enforce(expected: 81, read: unit.read, write: unit.write)
        #expect(check == .corrected(from: 152))
        #expect(unit.device == 81)
        #expect(check.note == "bridge_device_check=drift from=152 fixed=1")
    }

    @Test func uncorrectableDriftIsReported() {
        let unit = FakeAUHAL(152)
        unit.refusesWrites = true
        let check = BuiltinPin.enforce(expected: 81, read: unit.read, write: unit.write)
        #expect(check == .drift(from: 152) && check.note == "bridge_device_check=drift from=152 fixed=0")
    }

    // MARK: H4 — start-failure back-off

    @Test func afterAStartFailureOneRecoveryRunsThenTheRestWait() {
        var throttle = RecoveryThrottle()
        throttle.startFailed(at: 0)
        let admissions = [0.05, 0.1, 0.3, 0.9].map { throttle.request(at: $0) }
        #expect(admissions == [.now, .after(1.5), .coalesced, .coalesced])
        #expect(throttle.attempts == 1)                                    // within the first second
        throttle.deferredFired(at: 1.6)
        #expect(throttle.attempts == 2)
    }

    @Test func configurationChangeRightAfterOurRecoveryCountsAsAFailedStart() {
        var throttle = RecoveryThrottle()
        #expect(throttle.request(at: 10) == .now)
        guard case .after(let wait) = throttle.request(at: 10.4) else { Issue.record("not deferred"); return }
        #expect(abs(wait - 1.2) < 1e-9)                                    // due at 10 + 1.0 + 0.6
        #expect(throttle.request(at: 11.0) == .coalesced)
        throttle.deferredFired(at: 11.6)
        #expect(throttle.request(at: 14) == .now)                          // quiet again: immediate
        #expect(throttle.attempts == 3)
    }

    @Test func unrelatedConfigurationChangesAreNotDelayed() {
        var throttle = RecoveryThrottle()
        #expect([0, 1.5, 3, 4.5].map { throttle.request(at: $0) } == [.now, .now, .now, .now])
    }
}
