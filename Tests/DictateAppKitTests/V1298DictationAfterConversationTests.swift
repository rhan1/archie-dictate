import AVFoundation
import CryptoKit
import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// 1.29.8 (Archie 62.7.3 Fix 1, I4): ⌥⌥ right after a conversation. Replays 2026-11-17 04:57:03
/// (live-check-1117.log): the conversation releases its lease, the dictation starts 33 ms later, its first
/// start fails `mic_error=com.apple.coreaudio.avfaudio:-10868` (the route is still leaving call mode), the
/// lifecycle's one retry runs (`mic_retry=ok`) and the headset then delivers digital silence
/// (`bridge_src=builtin_fallback reason=headset_digital_silence`). Base: `recording_ms=0 capture_intervals=none`,
/// nothing kept → the host ends `error:silence`. Through the real `AudioRecorder` + `CaptureLifecycle` (the
/// host's start chain: `resetCapture`, then `beginRecordingAsync`), on fakes only: no device is opened.
@Suite("V1298DictationAfterConversation", .serialized)
struct V1298DictationAfterConversationTests {
    static let avf = "com.apple.coreaudio.avfaudio"
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    static func sha(_ s: [Float]) -> String {
        SHA256.hash(data: s.withUnsafeBufferPointer { Data(buffer: $0) }).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// The built-in AUHAL: delivers to its CURRENT start (a restarted unit's callbacks carry the new epoch).
    final class Builtin: BuiltinCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onDeviceLost: ((CaptureEpoch) -> Void)?
        private let lock = NSLock()
        private var running: CaptureEpoch?
        private(set) var starts = 0
        func start(epoch: CaptureEpoch) throws { lock.withLock { starts += 1; running = epoch } }
        func stop() { lock.withLock { running = nil } }
        func stop(epoch: CaptureEpoch) { lock.withLock { if running === epoch { running = nil } } }
        var isDelivering: Bool { true }
        var started: Bool { lock.withLock { running != nil } }
        var currentDeviceID: UInt32? { 81 }
        var expectedDeviceID: UInt32? { 81 }
        var lastBufferTime: TimeInterval? { nil }
        let backend = "fake"
        func deliver(_ value: Float, at time: TimeInterval) {
            guard let epoch = lock.withLock({ running }) else { return }
            onFrames?([Float](repeating: value, count: 2_400), time, epoch)
        }
    }

    /// The XM6 AUHAL client: the first `failFirst` starts throw −10868; a started client delivers digital zeros
    /// (A2DP: no microphone on the link).
    final class Headset: HeadsetCapture, @unchecked Sendable {
        var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
        var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)?
        private let lock = NSLock()
        private var epoch: CaptureEpoch?
        private var failures: Int
        private(set) var attempts = 0
        init(failFirst: Int) { failures = failFirst }
        func start(deviceUID: String, epoch: CaptureEpoch) throws {
            let fail = lock.withLock { () -> Bool in
                attempts += 1
                guard failures > 0 else { self.epoch = epoch; return false }
                failures -= 1
                return true
            }
            if fail { throw NSError(domain: V1298DictationAfterConversationTests.avf, code: -10868) }
            onEvent?(.started(deviceUID: deviceUID, sampleRate: 16_000, channels: 1), epoch)
        }
        func stop() { lock.withLock { epoch = nil } }
        func stop(epoch: CaptureEpoch) { lock.withLock { if self.epoch === epoch { self.epoch = nil } } }
        var isRunning: Bool { lock.withLock { epoch != nil } }
        var lastCallbackTime: TimeInterval? { nil }
        var formatGeneration: Int { 1 }
        var counters: SourceCounters { SourceCounters() }
        let backend = "auhal"
        func deliverZeros(at time: TimeInterval) {
            guard let epoch = lock.withLock({ self.epoch }) else { return }
            onFrames?([Float](repeating: 0, count: 2_400), time, epoch)
        }
    }

    struct Outcome {
        let ready: Bool, samples: [Float], recordingMs: Int, intervals: String, carrier: String, notes: [String]
        var release: CaptureLease.State? = nil, leaseFree = false
        /// What the host's outcome would be: no kept voice → `error:silence` (dict_levels max=0).
        var outcome: String { samples.contains { $0 != 0 } ? "pasted" : "error:silence" }
        var voiceMs: Int { samples.filter { $0 != 0 }.count / 24 }
        var line: String {
            "outcome=\(outcome) voice_ms=\(voiceMs) recording_ms=\(recordingMs) capture_intervals=\(intervals) carrier=\(carrier)"
                + " release=\(release.map { "\($0)" } ?? "nil") lease_free=\(leaseFree)"
        }
    }

    /// Path (b), XM6: a conversation's lease is released, then the dictation starts at once (the host's order).
    @MainActor static func xm6(failFirst: Int, seconds: TimeInterval = 3.0, cancelInWait: Bool = false) async throws -> Outcome {
        let broker = CaptureLeaseBroker()
        let route = CaptureLeaseRecorderTests.route                    // Bluetooth default input + a built-in
        let log = CaptureLeaseRecorderTests.Log()
        let (conversation, _, _) = CaptureLeaseRecorderTests.recorder("C", log, broker: broker)
        conversation.kind = .conversation
        try await conversation.startAsync(device: .default)
        conversation.resetCapture()
        _ = conversation.stop()
        _ = await conversation.awaitRelease()                           // lease_released … lease_kind=conversation

        let builtin = Builtin()
        let headset = Headset(failFirst: failFirst)
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .auhal, broker: broker, route: route)
        recorder.kind = .dictation
        let lifecycle = CaptureLifecycle(engine: recorder)
        let notes = CaptureLeaseRecorderTests.Log()
        lifecycle.note = { notes.append($0) }
        recorder.resetCapture()                                          // BT3: the boundary before either start
        let speaking = Task.detached {                                    // he speaks from the moment he pressed ⌥⌥
            let end = now() + seconds
            while now() < end {
                builtin.deliver(0.25, at: now())
                headset.deliverZeros(at: now())
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        final class Flag: @unchecked Sendable { var on = false }
        let cancelled = Flag()
        let ready = await lifecycle.beginRecordingAsync(at: now(),
            start: { try await recorder.startAsync(device: $0) }, rebuild: { try await recorder.rebuildAsync() },
            wait: { s in try? await Task.sleep(nanoseconds: UInt64(s * 1e9)); if cancelInWait { cancelled.on = true } },
            isCancelled: { cancelled.on })
        if !cancelInWait { await speaking.value }
        let samples = lifecycle.end(cancelInWait ? .cancel : .finished(.ok))   // the host's Esc / finish tap
        if cancelInWait { speaking.cancel() }
        let release = await recorder.awaitRelease()
        let next = broker.tryAcquire(.conversation)                          // the next ⌘⌘ gets the microphone
        let free = (try? next.get()) != nil
        if case .success(let lease) = next { lease.release() }
        let s = recorder.stats
        return Outcome(ready: ready, samples: samples, recordingMs: s.recordingMs, intervals: s.captureIntervals,
                       carrier: s.carrier, notes: notes.all, release: release, leaseFree: free)
    }

    /// Path (a), no headset: the Mac mic is the default input (the engine arm on the offline fake engine) and its
    /// first start after a Mac-mic conversation fails −10868 (the conversation's stale client format).
    @MainActor static func macMic(failFirst: Int, seconds: TimeInterval = 3.0) async throws -> Outcome {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let rig = V129InPlaceRouteApplyTests.Rig(hardware: format)
        rig.input = .builtin
        rig.defaultDevice = 81
        rig.engine.device = 81
        rig.fingerprint = "builtin:81:48000:1:1"
        final class Count: @unchecked Sendable { var left: Int; init(_ n: Int) { left = n } }
        let count = Count(failFirst)
        let engine = rig.engine
        engine.onStart = {
            engine.startError = count.left > 0 ? NSError(domain: V1298DictationAfterConversationTests.avf, code: -10868) : nil
            count.left -= 1
        }
        let watches = V1292RestartCancelTests.Watches()
        var probe = rig.probe
        probe.isRunningSomewhere = { _ in false }
        probe.watchDefaultInput = { _ in watches.make() }
        let broker = CaptureLeaseBroker()
        let recorder = AudioRecorder(builtin: { Builtin() }, headset: { Headset(failFirst: 0) }, backend: .engine,
                                     broker: broker, route: probe)
        recorder.kind = .dictation
        let make: (CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit = { [weak recorder] _ in
            CaptureInputUnit(start: { try recorder?.offlineInstallConvertingTapAndStart() }, dispose: {})
        }
        recorder.offlineConversationEngine = OfflineConversationEngine(
            native: { rig.engine.native }, rebuild: { try rig.rebuild() }, make: make)
        recorder.offlineEngineArmStarts = true
        let lifecycle = CaptureLifecycle(engine: recorder)
        let notes = CaptureLeaseRecorderTests.Log()
        lifecycle.note = { notes.append($0) }
        recorder.resetCapture()
        let speaking = Task.detached {
            let end = now() + seconds
            while now() < end {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
                buffer.frameLength = 4_800
                for i in 0..<4_800 { buffer.floatChannelData![0][i] = 0.25 }
                if engine.running { engine.deliver(buffer, at: now()) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let ready = await lifecycle.beginRecordingAsync(at: now(),
            start: { try await recorder.startAsync(device: $0) }, rebuild: { try await recorder.rebuildAsync() },
            wait: { s in try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }, isCancelled: { false })
        await speaking.value
        recorder.offlineDrainPCM()
        let samples = lifecycle.end(.finished(.ok))
        _ = await recorder.awaitRelease()
        let s = recorder.stats
        return Outcome(ready: ready, samples: samples, recordingMs: s.recordingMs, intervals: s.captureIntervals,
                       carrier: s.carrier, notes: notes.all)
    }

    /// RED on ebe3c30: `outcome=error:silence voice_ms=0 recording_ms=0 capture_intervals=none`.
    @Test @MainActor func dictation_right_after_conversation_xm6() async throws {
        let r = try await Self.xm6(failFirst: 1)
        print("F1 LITERAL dictation_right_after_conversation path=xm6 \(r.line) notes=\(r.notes.joined(separator: ","))")
        #expect(r.notes.contains { $0.hasPrefix("mic_error=\(Self.avf):-10868") })
        #expect(r.outcome == "pasted")
        #expect(r.voiceMs >= 2_500)                       // nothing he said in the first 3 s is lost (≤ 0.5 s slack)
        #expect(r.recordingMs > 0 && r.intervals != "none")
        #expect(r.release == .released && r.leaseFree)    // the kept session still ends: lease + built-in released
    }

    /// Fable 2 (archie-6273 read): Esc during the retry wait still releases everything the kept session held.
    @Test @MainActor func cancel_during_retry_wait_releases() async throws {
        let r = try await Self.xm6(failFirst: 1, cancelInWait: true)
        print("F1 LITERAL cancel_during_retry_wait ready=\(r.ready) \(r.line)")
        #expect(!r.ready && r.release == .released && r.leaseFree)
    }

    @Test @MainActor func dictation_right_after_conversation_mac_mic() async throws {
        let r = try await Self.macMic(failFirst: 1)
        print("F1 LITERAL dictation_right_after_conversation path=mac_mic \(r.line) notes=\(r.notes.joined(separator: ","))")
        #expect(r.notes.contains { $0.hasPrefix("mic_error=\(Self.avf):-10868") })
        #expect(r.outcome == "pasted")
        #expect(r.recordingMs > 0 && r.intervals != "none")
    }

    /// A dictation whose first start succeeds never reaches the changed branch: the same literal on base and fix.
    @Test @MainActor func cold_dictation_unchanged() async throws {
        let b = try await Self.xm6(failFirst: 0)
        let a = try await Self.macMic(failFirst: 0)
        print("F1 LITERAL cold_dictation path=xm6 \(b.line) notes=\(b.notes) path=mac_mic \(a.line) notes=\(a.notes)")
        #expect(b.outcome == "pasted" && a.outcome == "pasted" && !(b.notes + a.notes).contains { $0.contains("-10868") || $0.hasPrefix("mic_retry") })
        // (the harness never reports a first buffer to the lifecycle, so its 3 s watchdog line appears on base and fix alike)
        #expect(b.voiceMs >= 2_500 && a.voiceMs >= 2_500)
    }
}
