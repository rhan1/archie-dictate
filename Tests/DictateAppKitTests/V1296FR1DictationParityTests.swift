import AVFoundation
import CryptoKit
import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// archie-v73-fr1 Lane D (V-G1): a built-in-mic dictation (default input = the built-in, no Bluetooth) through the
/// real recorder (lease, input policy, production converting tap, feed, delivery, stop flush). Only the native
/// AVAudioEngine calls are faked (V129 FakeEngine via OfflineConversationEngine). The SAME source runs against
/// 11b8c3b and the fix-round head; the printed digests must be identical.
@Suite("V1296FR1DictationParity", .serialized)
struct V1296FR1DictationParityTests {
    typealias V129 = V129InPlaceRouteApplyTests
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [[Int16]] = []
        private var failures: [String] = []
        func add(_ c: [Int16]) { lock.withLock { chunks.append(c) } }
        func fail(_ f: CaptureFailure) { lock.withLock { failures.append(f.note) } }
        var all: [[Int16]] { lock.withLock { chunks } }
        var failed: [String] { lock.withLock { failures } }
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// 1.2 s of a 440 Hz tone plus a fixed pseudo-random floor, in twelve 100 ms 48 kHz buffers.
    static func buffers(_ format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        var seed: UInt32 = 0x1234_5678
        var n = 0
        return (0..<12).map { _ in
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            buffer.frameLength = 4_800
            let out = buffer.floatChannelData![0]
            for i in 0..<4_800 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.01
                out[i] = 0.25 * Float(sin(2 * Double.pi * 440 * Double(n) / 48_000)) + noise
                n += 1
            }
            return buffer
        }
    }

    @Test func builtin_mic_dictation_identical() async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let rig = V129.Rig(hardware: format)
        rig.input = .builtin            // default input = the Mac's built-in microphone; no Bluetooth anywhere
        rig.defaultDevice = 81
        rig.nextEngineDevice = 81
        rig.engine.device = 81
        rig.fingerprint = "builtin:81:48000:1:1"
        let log = V61CaptureLifetimeTests.Log()
        let builtin = V61CaptureLifetimeTests.FakeBuiltin("fr1.parity.builtin", log: log)
        let headset = V61CaptureLifetimeTests.FakeHeadset("fr1.parity.headset", log: log)
        let watches = V1292RestartCancelTests.Watches()
        var probe = rig.probe
        probe.isRunningSomewhere = { _ in false }
        probe.watchDefaultInput = { _ in watches.make() }
        let recorder = AudioRecorder(builtin: { builtin }, headset: { headset }, backend: .engine,
                                     broker: CaptureLeaseBroker(), route: probe)
        recorder.kind = .dictation
        let sink = Sink()
        recorder.onPCMChunk = { sink.add($0) }
        recorder.onCaptureFailure = { sink.fail($0) }
        let make: (CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit = { [weak recorder] _ in
            CaptureInputUnit(start: { try recorder?.offlineInstallConvertingTapAndStart() }, dispose: {})
        }
        recorder.offlineConversationEngine = OfflineConversationEngine(
            native: { rig.engine.native }, rebuild: { try rig.rebuild() }, make: make)
        let t0 = ProcessInfo.processInfo.systemUptime
        try recorder.offlineStartInput(at: t0, note: { _ in }, bridge: true, make: make)
        for (i, buffer) in Self.buffers(format).enumerated() {
            rig.engine.deliver(buffer, at: t0 + Double(i) * 0.1)
        }
        recorder.offlineDrainPCM()
        let beforeStop = sink.all.count
        let captured = recorder.stop()
        let release = await recorder.awaitRelease()
        let pcm = sink.all.flatMap { $0 }
        let pcmData = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        let capturedData = captured.withUnsafeBufferPointer { Data(buffer: $0) }
        let builtinStarts = builtin.startCount
        let outcome = "chunks=\(sink.all.count) chunks_before_stop=\(beforeStop) samples=\(pcm.count)"
            + " pcm_sha256=\(Self.sha(pcmData)) captured=\(captured.count) captured_sha256=\(Self.sha(capturedData))"
            + " failures=\(sink.failed.count) release=\(release.map { "\($0)" } ?? "nil") builtin_unit_starts=\(builtinStarts)"
            + " taps=\(rig.engine.counts.installs) engine_starts=\(rig.engine.counts.starts)"
        print("DPARITY builtin_mic_dictation \(outcome)")
        #expect(pcm.count > 24_000 && sink.failed.isEmpty)
    }
}
