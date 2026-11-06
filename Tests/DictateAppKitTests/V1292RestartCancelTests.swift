import AVFoundation
import CoreAudio
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

/// 1.29.2 D1: a stop (cancel and finish are the same stop) landing while a dictation's headset restart is in
/// flight. The REAL recorder runs: a Bluetooth dictation whose headset delivers only digital zeros through the
/// fake engine's tap → the bridge's restart decision → `requestHeadsetRestart` → the episode → `restartHeadset`
/// → `HeadsetRestart.perform` → `rebuildEngineAndStart` → the seam's rebuilt fake engine → its native start.
/// Only the native AVAudioEngine node and the route reads are faked. No microphone, device or audio.
@Suite("V1292RestartCancelTests", .serialized)
struct V1292RestartCancelTests {
    typealias V129 = V129InPlaceRouteApplyTests

    /// A live default-input watch token (an observer the recorder must release on stop).
    final class Watch {}
    final class Watches: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [WeakBox] = []
        struct WeakBox { weak var token: Watch? }
        func make() -> Watch { let w = Watch(); lock.withLock { tokens.append(WeakBox(token: w)) }; return w }
        var live: Int { lock.withLock { tokens.filter { $0.token != nil }.count } }
        var made: Int { lock.withLock { tokens.count } }
    }

    struct Session {
        let recorder: AudioRecorder
        let rig: V129.Rig
        let broker: CaptureLeaseBroker
        let watches: Watches
    }

    /// `running`: the restart's idle check (`isRunningSomewhere` on the headset device).
    static func start(running: @escaping @Sendable (AudioDeviceID) -> Bool? = { _ in false }) throws -> Session {
        let rig = V129.Rig()
        let watches = Watches()
        let log = V61CaptureLifetimeTests.Log()
        let builtin = V61CaptureLifetimeTests.FakeBuiltin("v1292.builtin", log: log)
        let headset = V61CaptureLifetimeTests.FakeHeadset("v1292.headset", log: log)
        var probe = rig.probe
        probe.isRunningSomewhere = running
        probe.watchDefaultInput = { _ in watches.make() }
        let broker = CaptureLeaseBroker()
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .engine, broker: broker, route: probe)
        recorder.kind = .dictation
        let make: (CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit = { [weak recorder] _ in
            CaptureInputUnit(start: { try recorder?.offlineInstallConvertingTapAndStart() }, dispose: {})
        }
        recorder.offlineConversationEngine = OfflineConversationEngine(
            native: { rig.engine.native }, rebuild: { try rig.rebuild() }, make: make)
        try recorder.offlineStartInput(at: ProcessInfo.processInfo.systemUptime, note: { _ in }, bridge: true, make: make)
        return Session(recorder: recorder, rig: rig, broker: broker, watches: watches)
    }

    /// The headset delivers 1 s of digital zeros through the live tap: the bridge asks for its one restart.
    /// Waits for the restart's `headset_restart=1 path=` line (the real executor runs it).
    static func silentHeadsetUntilRestart(_ s: Session) -> String? {
        let t0 = ProcessInfo.processInfo.systemUptime
        for i in 0..<10 {
            s.rig.engines[0].deliver(V129.sine(rate: 16_000, channels: 1, frames: 1_600, amplitude: 0), at: t0 + Double(i) * 0.1)
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            // The recorder's own copy of its restart line (the global note sink is shared by concurrent suites).
            let line = s.recorder.headsetRestartNote
            if line != "none" { return line }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    /// `recorder.stop()` from another thread, waited for (bounded).
    static func stopFromAnotherThread(_ recorder: AudioRecorder) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = recorder.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 5)
    }

    static func finish(_ s: Session) async -> CaptureLease.State? {
        _ = s.recorder.stop()
        return await s.recorder.awaitRelease()
    }

    @Test func stopDuringTheRestartsStartNeverStopsIOMillisecondsAfterTheStart() async throws {
        let s = try Self.start()
        s.rig.onNewEngine = { [weak recorder = s.recorder] engine in
            engine.onStart = {
                engine.onStart = nil
                if let recorder { Self.stopFromAnotherThread(recorder) }   // the user cancels mid-restart
            }
        }
        let line = try #require(Self.silentHeadsetUntilRestart(s))
        let candidate = try #require(s.rig.engines.count > 1 ? s.rig.engines[1] : nil)
        let starts = candidate.startTimes.count
        let stopMs: Int? = candidate.startTimes.first.flatMap { started in
            candidate.removeTimes.first(where: { $0 >= started }).map { Int((($0 - started) * 1000).rounded()) }
        }
        let errorNote = s.recorder.headsetRestartDiagnostics.errors > 0
        let cancelled = V129.field("cancelled", line)
        _ = await Self.finish(s)
        let green = !errorNote && (starts == 0 || (stopMs ?? 0) >= 300)
        if green {
            print("D1 GREEN starts=\(starts) stop_after_start_ms=\(stopMs.map(String.init) ?? "-") cancelled=\(cancelled ?? "none") note=\(line)")
        } else {
            print("D1 RED starts=\(starts) stop_after_start_ms=\(stopMs.map(String.init) ?? "-") note=\(errorNote ? "headset_restart_error" : line)")
        }
        #expect(!errorNote)
        #expect(starts == 0 || (stopMs ?? 0) >= 300)
        #expect(cancelled == (starts == 0 ? "before_start" : "after_start"))
        #expect(V129.field("started", line) == "0")
    }

    @Test func twinStopInTheIdlePollNeverStarts() async throws {
        final class Box: @unchecked Sendable { weak var recorder: AudioRecorder?; var fired = false }
        let box = Box()
        let s = try Self.start(running: { _ in
            if !box.fired, let recorder = box.recorder { box.fired = true; Self.stopFromAnotherThread(recorder) }
            return false
        })
        box.recorder = s.recorder
        let line = try #require(Self.silentHeadsetUntilRestart(s))
        let starts = s.rig.engines.dropFirst().reduce(0) { $0 + $1.startTimes.count }
        _ = await Self.finish(s)
        print("D1 TWIN stop-in-poll starts=\(starts) fired=\(box.fired ? 1 : 0) note=\(line)")
        #expect(box.fired)
        #expect(starts == 0)
    }

    @Test func controlWithoutAStopStartsTheHeadsetAgain() async throws {
        let s = try Self.start()
        let line = try #require(Self.silentHeadsetUntilRestart(s))
        let candidate = try #require(s.rig.engines.count > 1 ? s.rig.engines[1] : nil)
        let starts = candidate.startTimes.count
        _ = await Self.finish(s)
        print("D1 CONTROL no-stop starts=\(starts) started=\(V129.field("started", line) ?? "?") note=\(line)")
        #expect(starts == 1)
        #expect(V129.field("started", line) == "1")
        #expect(V129.field("cancelled", line) == nil)
        #expect(s.recorder.headsetRestartDiagnostics.errors == 0)
    }

    @Test func leaseIsReleasedAfterTheCancelledRestartsTeardownAndNothingRecoversAfterStop() async throws {
        let s = try Self.start()
        s.rig.onNewEngine = { [weak recorder = s.recorder] engine in
            engine.onStart = {
                engine.onStart = nil
                if let recorder { Self.stopFromAnotherThread(recorder) }
            }
        }
        #expect(s.watches.made == 1)                               // the start's default-input watch
        final class Released: @unchecked Sendable { let lock = NSLock(); var at: TimeInterval? }
        let released = Released()
        let lease = try #require(s.recorder.currentLease)
        lease.whenSettled { _ in released.lock.withLock { released.at = ProcessInfo.processInfo.systemUptime } }
        let line = try #require(Self.silentHeadsetUntilRestart(s))
        let atRestart = s.recorder.headsetRestartDiagnostics
        let state = await s.recorder.awaitRelease()
        let candidate = try #require(s.rig.engines.count > 1 ? s.rig.engines[1] : nil)
        let teardownAt = candidate.removeTimes.last ?? .infinity
        // Let any straggling work (a busy retry, a verification, a recovery) surface before reading the counters.
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let end = s.recorder.headsetRestartDiagnostics
        let recoveries = (end.restarts - atRestart.restarts) + (end.requests - atRestart.requests) + end.errors
        let releasedAfterTeardown = released.lock.withLock { released.at }.map { $0 >= teardownAt } ?? false
        let observers = s.watches.live
        print("D1 LEASE released_after_teardown=\(releasedAfterTeardown ? 1 : 0) observers=\(observers) state=\(state.map { "\($0)" } ?? "nil") lease_active=\(s.recorder.currentLease == nil ? 0 : 1) recoveries_after_stop=\(recoveries) note=\(line)")
        #expect(state == .released)
        #expect(s.recorder.currentLease == nil)
        #expect(releasedAfterTeardown)
        #expect(observers == 0)
        #expect(recoveries == 0)
    }
}
