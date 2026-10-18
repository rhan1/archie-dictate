import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// Self-test fix (Archie 53.3 relaunch, 10-18 14:06): the injected WAV flows (levels > 0) but plain inject mode
/// judged the stream by its exact-zero tail and ended the dictation with `error:mic_dead` before the rig wrote its text.
/// Plain injection delivers a frame every tick by construction, so silent PCM (leading/trailing zeros, EOF) is intentional.
/// Dead-stream scenarios (`builtin_dies`) and the real recorder keep failing.
@Suite("InjectedHealth")
struct InjectedHealthTests {
    /// 1 s of tone, then 0.4 s speech-like gap, like raza-question.wav: leading zeros, speech, zeros to EOF.
    private static func samples() -> [Int16] {
        let lead = [Int16](repeating: 0, count: 17 * 2_400 / 10)
        let tone = (0..<Int(1.0 * 24_000)).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
        return lead + tone + [Int16](repeating: 0, count: 2_400)
    }

    private func run(_ scenario: WAVInjectedRecorder.Scenario, mediaSeconds: Double) async throws
        -> (failure: CaptureFailure?, pcmSamples: Int, callbacks: Int) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-injhealth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.wav")
        try WAVEncoder.encode(samples: Self.samples(), sampleRate: 24_000, channels: 1).write(to: url)
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: scenario)
        let lock = NSLock()
        var pcm = 0
        var callbacks = 0
        var failure: CaptureFailure?
        recorder.note = { _ in }
        recorder.onPCMChunk = { chunk in lock.withLock { pcm += chunk.count; callbacks += 1 } }
        recorder.onCaptureFailure = { found in lock.withLock { failure = found } }
        recorder.manualPacing = true
        try recorder.start()
        recorder.resetCapture()
        for _ in 0..<Int(mediaSeconds * 10 + 0.5) {
            recorder.step()
            await MainActor.run {}                       // the failure callback hops to main
            if lock.withLock({ failure }) != nil { break }
        }
        _ = recorder.stop()
        return (lock.withLock { failure }, lock.withLock { pcm }, lock.withLock { callbacks })
    }

    /// RED today: the exact-zero tail past the last non-zero sample ends the injected dictation with mic_dead.
    @Test func plainInjectionSurvivesSilentTailAndKeepsDelivering() async throws {
        let result = try await run(.plain, mediaSeconds: 9)
        #expect(result.failure == nil)
        #expect(result.callbacks >= 85)                  // frames kept flowing the whole 9 s
    }

    /// Positive control: a stream that really dies still ends with mic_dead.
    @Test func deadInjectedStreamStillFailsMicDead() async throws {
        let result = try await run(.builtinDies, mediaSeconds: 9)
        let failure = try #require(result.failure)
        #expect(failure.reason == .micDead)
    }
}
