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
        func stop() -> Bool { log.append("stop@\(ms)"); return true }
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
        #expect(fake.log == ["stop@0", "start@400"])                  // idle at 100 ms + 300 ms settle (v1.8)
        #expect(outcome == .init(waitedMs: 400, deviceIdle: true, started: true))
    }

    @Test func restartPollIsBoundedAt400ms() {
        let fake = FakeHeadset()
        fake.busyUntil = 10
        let outcome = HeadsetRestart.perform(stop: fake.stop, isRunningSomewhere: fake.running,
                                             sleep: fake.sleep, start: fake.start, note: { _ in })
        #expect(fake.log == ["stop@0", "start@700"])
        #expect(!outcome.deviceIdle && outcome.started)
        let unreadable = FakeHeadset()
        unreadable.unreadable = true
        _ = HeadsetRestart.perform(stop: unreadable.stop, isRunningSomewhere: unreadable.running,
                                   sleep: unreadable.sleep, start: unreadable.start, note: { _ in })
        #expect(unreadable.log == ["stop@0", "start@700"])
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

    // MARK: H4 → v1.8 L3 — RecoveryThrottle folded into BluetoothRecoveryEpisode

    @Test func afterAStartFailureOneRecoveryRunsThenTheRestWait() {
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        #expect(episode.request(.startRetry, at: 0) == .now)
        let first = episode.begin(at: 0)
        #expect(first)
        let during = [episode.request(.configuration, at: 0.1), episode.request(.configuration, at: 0.3)]
        #expect(during == [.coalesced, .coalesced])
        episode.settled(.noFrames)
        #expect(episode.request(.restart, at: 0.9) == .after(0.6))         // next window opens at 1.5
        #expect(episode.request(.firstBuffer, at: 1.0) == .coalesced)
        let second = episode.begin(at: 1.5)
        #expect(second)
        #expect(episode.attempts == 2)
    }

    @Test func configurationChangeRightAfterOurRecoveryCountsAsAFailedStart() {
        // A notification storm: the stable-format debounce is bounded by the window.
        var episode = BluetoothRecoveryEpisode(bluetooth: true)
        for step in 0...20 { episode.formatChanged(at: 10 + Double(step) * 0.1) }
        guard case .after(let wait) = episode.request(.configuration, at: 10) else { Issue.record("not deferred"); return }
        #expect(abs(wait - 1.5) < 1e-9)                                    // 10 + window, not 12.2
        var quiet = BluetoothRecoveryEpisode(bluetooth: true)
        quiet.formatChanged(at: 20)
        guard case .after(let debounce) = quiet.request(.configuration, at: 20.05) else { Issue.record("no debounce"); return }
        #expect(abs(debounce - 0.15) < 1e-9)                               // stable 200 ms after the change
    }

    @Test func unrelatedConfigurationChangesAreNotDelayed() {
        var episode = BluetoothRecoveryEpisode(bluetooth: false)               // non-Bluetooth: prompt recovery
        var admissions: [BluetoothRecoveryEpisode.Admission] = []
        for time in [0, 0.1, 0.2, 1.5] { admissions.append(episode.request(.configuration, at: time)) }
        #expect(admissions == [.now, .now, .now, .now])
        #expect(episode.attempts == 4)
    }
}
