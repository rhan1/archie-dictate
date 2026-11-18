import AVFoundation
import CoreAudio
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

/// 1.29.10 F1: Esc (`recorder.stop()` from another thread) landing during a Bluetooth dictation's
/// start, retry start, or headset restart. Hardware-free via `V129InPlaceRouteApplyTests.Rig` +
/// `OfflineConversationEngine`.
@Suite("V12910EscDuringStartTests", .serialized)
struct V12910EscDuringStartTests {
    typealias V129 = V129InPlaceRouteApplyTests

    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var on: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private final class EngineRef: @unchecked Sendable {
        private let lock = NSLock()
        private var value: V129.FakeEngine
        init(_ engine: V129.FakeEngine) { value = engine }
        var engine: V129.FakeEngine {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private struct TimingMeasurement {
        let name: String
        let starts: Int
        let stopAfterStartMs: Int?
        let release: CaptureLease.State?
        let ioLeft: Int

        var passed: Bool {
            ioLeft == 0 && release == .released && (starts == 0 || (stopAfterStartMs ?? -1) >= 300)
        }

        var line: String {
            let ms = stopAfterStartMs.map(String.init) ?? "-"
            let rel = release.map { "\($0)" } ?? "nil"
            return "ESC timing=\(name) starts=\(starts) stop_after_start_ms=\(ms) release=\(rel) io_left=\(ioLeft) result=\(passed ? "PASS" : "FAIL")"
        }
    }

    /// The fake has no native stop (`running` never clears); a teardown shows as `removeTap`. IO is left when the
    /// engine's last start has no removeTap at or after it.
    private static func ioLeft(_ engine: V129.FakeEngine) -> Bool {
        guard let started = engine.startTimes.last else { return false }
        return !engine.removeTimes.contains { $0 >= started }
    }

    private static func stopAfterStartMs(on engine: V129.FakeEngine?) -> (starts: Int, stopMs: Int?) {
        guard let engine else { return (0, nil) }
        let starts = engine.startTimes.count
        let stopMs = engine.startTimes.first.flatMap { started in
            engine.removeTimes.first(where: { $0 >= started }).map { Int((($0 - started) * 1000).rounded()) }
        }
        return (starts, stopMs)
    }

    @MainActor
    private static func makeStartRecorder(rig: V129.Rig) -> (AudioRecorder, CaptureLifecycle, V1292RestartCancelTests.Watches) {
        let watches = V1292RestartCancelTests.Watches()
        var probe = rig.probe
        probe.isRunningSomewhere = { _ in false }
        probe.watchDefaultInput = { _ in watches.make() }
        let broker = CaptureLeaseBroker()
        let recorder = AudioRecorder(
            builtin: { V1298DictationAfterConversationTests.Builtin() },
            headset: { V1298DictationAfterConversationTests.Headset(failFirst: 0) },
            backend: .engine,
            broker: broker,
            route: probe)
        recorder.kind = .dictation
        let make: (CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit = { [weak recorder] _ in
            CaptureInputUnit(start: { try recorder?.offlineInstallConvertingTapAndStart() }, dispose: {})
        }
        recorder.offlineConversationEngine = OfflineConversationEngine(
            native: { rig.engine.native }, rebuild: { try rig.rebuild() }, make: make)
        recorder.offlineEngineArmStarts = true
        let lifecycle = CaptureLifecycle(engine: recorder)
        return (recorder, lifecycle, watches)
    }

    @MainActor
    private static func runWarmingEsc() async -> TimingMeasurement {
        let rig = V129.Rig() // Bluetooth defaults: input = .bluetooth, device 77, 16 kHz hardware
        let (recorder, lifecycle, watches) = makeStartRecorder(rig: rig)
        let firstEngine = rig.engine
        let cancelled = AtomicFlag()
        firstEngine.onStart = { [weak recorder, weak firstEngine] in
            firstEngine?.onStart = nil
            cancelled.on = true
            if let recorder { V1292RestartCancelTests.stopFromAnotherThread(recorder) }
        }
        recorder.resetCapture()
        defer { withExtendedLifetime(watches) {} }
        _ = await lifecycle.beginRecordingAsync(
                at: ProcessInfo.processInfo.systemUptime,
                start: { try await recorder.startAsync(device: $0) },
                rebuild: { try await recorder.rebuildAsync() },
                wait: { s in try? await Task.sleep(nanoseconds: UInt64(min(s, 8.0) * 1e9)) },
                isCancelled: { cancelled.on })
        _ = lifecycle.end(.cancel)
        let release = await recorder.awaitRelease()
        let (starts, stopMs) = stopAfterStartMs(on: firstEngine)
        let ioLeft = rig.engines.contains(where: Self.ioLeft) ? 1 : 0
        return TimingMeasurement(name: "warming", starts: starts, stopAfterStartMs: stopMs, release: release, ioLeft: ioLeft)
    }

    @MainActor
    private static func runRetryStartEsc() async -> TimingMeasurement {
        let rig = V129.Rig() // Bluetooth defaults: input = .bluetooth, device 77, 16 kHz hardware
        let (recorder, lifecycle, watches) = makeStartRecorder(rig: rig)
        let cancelled = AtomicFlag()
        let retryEngine = EngineRef(rig.engine)
        let attempts = NSLock()
        var callCount = 0

        let attachHook: (V129.FakeEngine) -> Void = { engine in
            engine.onStart = { [weak recorder, weak engine] in
                guard let engine else { return }
                let call = attempts.withLock { () -> Int in
                    callCount += 1
                    return callCount
                }
                if call == 1 {
                    engine.startError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
                } else {
                    engine.startError = nil
                    engine.onStart = nil
                    retryEngine.engine = engine
                    cancelled.on = true
                    if let recorder { V1292RestartCancelTests.stopFromAnotherThread(recorder) }
                }
            }
        }
        attachHook(rig.engine)
        rig.onNewEngine = { engine in
            attachHook(engine)
        }

        recorder.resetCapture()
        defer { withExtendedLifetime(watches) {} }
        _ = await lifecycle.beginRecordingAsync(
                at: ProcessInfo.processInfo.systemUptime,
                start: { try await recorder.startAsync(device: $0) },
                rebuild: { try await recorder.rebuildAsync() },
                wait: { s in try? await Task.sleep(nanoseconds: UInt64(min(s, 8.0) * 1e9)) },
                isCancelled: { cancelled.on })
        _ = lifecycle.end(.cancel)
        let release = await recorder.awaitRelease()
        let (starts, stopMs) = stopAfterStartMs(on: retryEngine.engine)
        let ioLeft = rig.engines.contains(where: Self.ioLeft) ? 1 : 0
        return TimingMeasurement(name: "retry_start", starts: starts, stopAfterStartMs: stopMs, release: release, ioLeft: ioLeft)
    }

    private static func runRestartIdlePollEsc() async throws -> TimingMeasurement {
        final class Box: @unchecked Sendable {
            weak var recorder: AudioRecorder?
            var fired = false
        }
        let box = Box()
        let s = try V1292RestartCancelTests.start(running: { _ in
            if !box.fired, let recorder = box.recorder {
                box.fired = true
                V1292RestartCancelTests.stopFromAnotherThread(recorder)
            }
            return false
        })
        box.recorder = s.recorder
        _ = V1292RestartCancelTests.silentHeadsetUntilRestart(s)
        let candidate = s.rig.engines.dropFirst().last
        let release = await V1292RestartCancelTests.finish(s)
        let (starts, stopMs) = stopAfterStartMs(on: candidate)
        let ioLeft = s.rig.engines.contains(where: Self.ioLeft) ? 1 : 0
        return TimingMeasurement(name: "restart_idle_poll", starts: starts, stopAfterStartMs: stopMs, release: release, ioLeft: ioLeft)
    }

    private static func runRestartBeforeStartEsc() async throws -> TimingMeasurement {
        let s = try V1292RestartCancelTests.start()
        s.rig.onNewEngine = { [weak recorder = s.recorder] _ in
            if let recorder { V1292RestartCancelTests.stopFromAnotherThread(recorder) }
        }
        _ = V1292RestartCancelTests.silentHeadsetUntilRestart(s)
        let candidate = s.rig.engines.dropFirst().last
        let release = await V1292RestartCancelTests.finish(s)
        let (starts, stopMs) = stopAfterStartMs(on: candidate)
        let ioLeft = s.rig.engines.contains(where: Self.ioLeft) ? 1 : 0
        return TimingMeasurement(name: "restart_before_start", starts: starts, stopAfterStartMs: stopMs, release: release, ioLeft: ioLeft)
    }

    private static func runRestartInStartEsc() async throws -> TimingMeasurement {
        let s = try V1292RestartCancelTests.start()
        s.rig.onNewEngine = { [weak recorder = s.recorder] engine in
            engine.onStart = {
                engine.onStart = nil
                if let recorder { V1292RestartCancelTests.stopFromAnotherThread(recorder) }
            }
        }
        _ = V1292RestartCancelTests.silentHeadsetUntilRestart(s)
        let candidate = s.rig.engines.dropFirst().last
        let release = await V1292RestartCancelTests.finish(s)
        let (starts, stopMs) = stopAfterStartMs(on: candidate)
        let ioLeft = s.rig.engines.contains(where: Self.ioLeft) ? 1 : 0
        return TimingMeasurement(name: "restart_in_start", starts: starts, stopAfterStartMs: stopMs, release: release, ioLeft: ioLeft)
    }

    @Test @MainActor func esc_during_headset_start_and_restart() async throws {
        let measurements: [TimingMeasurement] = [
            await Self.runWarmingEsc(),
            await Self.runRetryStartEsc(),
            try await Self.runRestartIdlePollEsc(),
            try await Self.runRestartBeforeStartEsc(),
            try await Self.runRestartInStartEsc(),
        ]
        for m in measurements {
            print(m.line)
        }
        let fails = measurements.filter { !$0.passed }.count
        print("P \(fails == 0 ? "GREEN" : "RED") esc_during_headset_restart_restores_a2dp fails=\(fails)/5")
        #expect(fails == 0)
    }

    @Test @MainActor func esc_mac_mic_start_unchanged() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let rig = V129.Rig(hardware: format)
        rig.input = .builtin
        rig.defaultDevice = 81
        rig.engine.device = 81
        rig.fingerprint = "builtin:81:48000:1:1"
        let (recorder, lifecycle, watches) = Self.makeStartRecorder(rig: rig)
        let firstEngine = rig.engine
        let cancelled = AtomicFlag()
        firstEngine.onStart = { [weak recorder, weak firstEngine] in
            firstEngine?.onStart = nil
            cancelled.on = true
            if let recorder { V1292RestartCancelTests.stopFromAnotherThread(recorder) }
        }
        recorder.resetCapture()
        defer { withExtendedLifetime(watches) {} }
        _ = await lifecycle.beginRecordingAsync(
                at: ProcessInfo.processInfo.systemUptime,
                start: { try await recorder.startAsync(device: $0) },
                rebuild: { try await recorder.rebuildAsync() },
                wait: { s in try? await Task.sleep(nanoseconds: UInt64(min(s, 8.0) * 1e9)) },
                isCancelled: { cancelled.on })
        _ = lifecycle.end(.cancel)
        let release = await recorder.awaitRelease()
        let (starts, stopMs) = Self.stopAfterStartMs(on: firstEngine)
        let stopAfterStartMs = try #require(stopMs)
        #expect(starts == 1)
        #expect(stopAfterStartMs < 300)
        #expect(release == .released)
        print("P GREEN esc_mac_mic_unchanged=1 stop_after_start_ms=\(stopAfterStartMs)")
    }
}
