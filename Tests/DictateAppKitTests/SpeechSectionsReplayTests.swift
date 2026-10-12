import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.10 L2: `speech_sections` must describe the audio the transcriber got on a fallback run.
/// The passage models the 10-13 07:00–07:10 built-in at headset distance (R3 c35bde97:
/// `peak_dbfs=-28.4`, `speech_sections=0`): speech windows ≈ −43 dBFS RMS (noise-like syllables,
/// crest ≈ 12–16 dB) over a −52 dBFS room floor — below v1.9's −40 dBFS absolute rule and less
/// than its +12 dB relative rule. Synthetic levels only; no audio is kept after the test.
@Suite("SpeechSectionsReplay")
struct SpeechSectionsReplayTests {
    static let rate = 24_000
    /// Deterministic noise (sum of four uniforms ≈ Gaussian), unit variance.
    struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            var sum = 0.0
            for _ in 0..<4 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                sum += Double(state >> 11) / Double(1 << 53) - 0.5
            }
            return sum * (12.0 / 4).squareRoot()
        }
    }
    static func samples(_ segments: [(seconds: Double, speech: Bool)], room: Double = 0.0025,
                        speech: Double = 0.0063, seed: UInt64 = 7) -> [Int16] {
        var noise = Noise(state: seed)
        var out: [Int16] = []
        for segment in segments {
            let n = Int(segment.seconds * Double(rate))
            for i in 0..<n {
                // Syllables: 150 ms on, 60 ms off.
                let inSyllable = segment.speech && (i % Int(0.21 * Double(rate))) < Int(0.15 * Double(rate))
                var v = room * noise.next()
                if inSyllable { v += speech * noise.next() }
                out.append(Int16(max(-32768, min(32767, (v * 32768).rounded()))))
            }
        }
        return out
    }
    /// Two sentences, a 2 s pause, two sentences, after 1.5 s of room noise (the headset's
    /// digital-zero fallback window).
    static var standardPassage: [Int16] {
        samples([(1.5, false), (1.6, true), (0.4, false), (1.6, true), (2.0, false),
                 (1.6, true), (0.4, false), (1.6, true), (1.0, false)])
    }

    private func runFallback(_ samples: [Int16]) async throws -> (stats: AudioRecorder.CaptureStats, pcm: [Int16], envelope: [Float]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-l2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("passage.wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1).write(to: url)
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: .headsetZeros)
        recorder.note = { _ in }
        let lock = NSLock()
        var pcm: [Int16] = []
        recorder.onPCMChunk = { chunk in lock.withLock { pcm += chunk } }
        try recorder.start()
        recorder.resetCapture()
        let deadline = ContinuousClock.now + .seconds(10)
        while lock.withLock({ pcm.count }) < samples.count, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = recorder.stop()
        return (recorder.stats, lock.withLock { pcm }, recorder.levelEnvelope)
    }

    private static func rmsWindows(_ pcm: [Int16]) -> [Float] {
        stride(from: 0, to: pcm.count - CaptureEvidence.windowFrames + 1, by: CaptureEvidence.windowFrames).map { start in
            let window = pcm[start..<(start + CaptureEvidence.windowFrames)]
            let sum = window.reduce(0.0) { $0 + Double($1) * Double($1) / (32768.0 * 32768.0) }
            return Float((sum / Double(window.count)).squareRoot())
        }
    }
    private static func db(_ x: Float) -> String { x <= 0 ? "-inf" : String(format: "%.1f", 20 * log10(Double(x))) }

    /// The replay: the RMS series the evidence judged IS the series of the frames the transcriber got.
    @Test func evidenceSeesTheKeptFrames() async throws {
        let passage = Self.standardPassage
        let run = try await runFallback(passage)
        #expect(run.stats.bridgeSource == "builtin_fallback")
        let kept = Self.rmsWindows(run.pcm)
        let compared = min(run.envelope.count, kept.count)
        #expect(compared >= passage.count / CaptureEvidence.windowFrames - 1)
        let maxDiff = zip(run.envelope.prefix(compared), kept.prefix(compared)).map { abs($0 - $1) }.max() ?? 1
        // pcm16 quantization only (≤ 1 LSB = 3.1e-5).
        #expect(maxDiff < 4e-5)
        let floor = run.envelope.sorted()[Int(Double(run.envelope.count - 1) * 0.1)]
        print("L2 replay windows=\(compared) max_abs_diff=\(maxDiff) p10_dbfs=\(Self.db(floor)) peak_window_dbfs=\(Self.db(run.envelope.max() ?? 0))")
        print("L2 replay evidence_dbfs[30..<70]=" + run.envelope[30..<70].map(Self.db).joined(separator: ","))
        print("L2 replay kept_dbfs[30..<70]=" + kept[30..<70].map(Self.db).joined(separator: ","))
    }

    @Test func fallbackPassageCountsAtLeast3Sections() async throws {
        let run = try await runFallback(Self.standardPassage)
        #expect(run.stats.bridgeSource == "builtin_fallback")
        #expect(run.stats.speechSections >= 3)
    }

    @Test func zerosOnlyCounts0() {
        for samples in [[Int16](repeating: 0, count: 5 * Self.rate),
                        Self.samples([(5, false)]),                                     // constant room noise
                        Self.samples([(5, false)], room: 0.0005)] {                    // quiet room
            var evidence = CaptureEvidence()
            evidence.start(at: 0)
            evidence.append(samples.map { Float($0) / 32768 }, at: 0)
            #expect(evidence.finalSpeechSections == 0)
        }
    }

    /// A warm-up dictation ("Hey, testing.") at the same distance: one phrase in 3 s.
    @Test func warmUpRunsCount1OrMore() {
        var evidence = CaptureEvidence()
        evidence.start(at: 0)
        evidence.append(Self.samples([(1.0, false), (1.0, true), (1.0, false)]).map { Float($0) / 32768 }, at: 0)
        #expect(evidence.finalSpeechSections >= 1)
    }
}
