import AVFoundation
import Foundation
import Testing
@testable import DictateAppKit

/// The processed (voice-processing) arm must not lose or repeat samples at callback boundaries.
/// One PCM second goes through the SAME production recorder converter either as one callback or as
/// ten; no IO unit is involved. AVAudioConverter's sample-rate converter holds back its trailing
/// look-ahead until end-of-stream (priming), and how much it holds depends on the call pattern
/// (b74b068 measured the same: whole=22520 streamed=23928 at 48 kHz, both 24000 once flushed). So
/// the comparison is the end-of-stream-flushed, sample-aligned signal — never the live counts.
@Suite
struct C1ConversionContinuityTests {
    enum Mutation { case none, dropSample, repeatSample }

    static func chirp(_ t: Double) -> Float { Float(0.1 * sin(2 * .pi * (220 * t + 170 * t * t))) }

    struct Run { var live: [Float]; var tail: [Float]; var state: String; var flushed: [Float] { live + tail } }

    func converted(rate: Double, framesPerCallback: Int, mutation: Mutation = .none) throws -> Run {
        let recorder = C1VoiceProcessingTests().recorder()
        try recorder.startCaptureInput { _ in CaptureInputUnit(start: {}, dispose: {}) }
        var output: [Float] = []
        recorder.headsetNative.converted = { output += $0 }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        for (index, offset) in stride(from: 0, to: Int(rate), by: framesPerCallback).enumerated() {
            var samples = (offset..<min(offset + framesPerCallback, Int(rate))).map { Self.chirp(Double($0) / rate) }
            // Positive controls: a boundary defect in the fifth callback must be detected.
            if index == 5 {
                if mutation == .dropSample { samples.removeFirst() }
                if mutation == .repeatSample { samples.insert(samples[0], at: 0) }
            }
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (i, sample) in samples.enumerated() {
                buffer.floatChannelData![0][i] = sample
                buffer.floatChannelData![1][i] = sample
            }
            recorder.offlineHeadsetBuffer(buffer)
        }
        return Run(live: output, tail: try recorder.offlineFlushConverter(), state: recorder.stats.voiceProcessing)
    }

    /// Largest per-sample difference; a length mismatch is a failure in itself.
    static func maxError(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? .infinity
    }

    /// Against the ideal chirp at 24 kHz (the converter is zero-latency once flushed). Edges skipped.
    static func alignmentError(_ x: [Float]) -> Float {
        x.indices.dropFirst(64).dropLast(64).map { abs(x[$0] - chirp(Double($0) / 24_000)) }.max() ?? .infinity
    }

    @Test func callbackBoundariesPreserveTheContinuousSignal() throws {
        for rate in [48_000.0, 44_100.0] {
            let whole = try converted(rate: rate, framesPerCallback: Int(rate))
            let streamed = try converted(rate: rate, framesPerCallback: Int(rate) / 10)
            #expect(whole.state == "on" && streamed.state == "on")
            #expect(whole.flushed.count == 24_000)
            #expect(streamed.flushed.count == whole.flushed.count)
            let error = Self.maxError(whole.flushed, streamed.flushed)
            #expect(error <= 0.00001)
            #expect(Self.alignmentError(whole.flushed) <= 0.0001)
            #expect(Self.alignmentError(streamed.flushed) <= 0.0001)
            print("C1 CONTINUITY rate=\(Int(rate)) whole=\(whole.flushed.count) streamed=\(streamed.flushed.count) max_err=\(error) cause=priming")
            print("C1 CONTINUITY detail rate=\(Int(rate)) whole_live=\(whole.live.count) whole_held=\(whole.tail.count) streamed_live=\(streamed.live.count) streamed_held=\(streamed.tail.count) align_err=\(Self.alignmentError(streamed.flushed))")
        }
    }

    @Test func droppedOrRepeatedBoundarySampleIsDetected() throws {
        let whole = try converted(rate: 48_000, framesPerCallback: 48_000)
        for mutation in [Mutation.dropSample, .repeatSample] {
            let broken = try converted(rate: 48_000, framesPerCallback: 4_800, mutation: mutation)
            let error = Self.maxError(whole.flushed, broken.flushed)
            let misaligned = Self.alignmentError(broken.flushed)
            #expect(error > 0.00001 && misaligned > 0.0001)
            print("C1 CONTINUITY CONTROL \(mutation) detected=\(error > 0.00001 && misaligned > 0.0001 ? 1 : 0) count=\(broken.flushed.count) max_err=\(error) align_err=\(misaligned)")
        }
    }
}
