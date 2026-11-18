import AVFoundation
import Foundation
import Testing
@testable import DictateCore

/// 1.29.11 (Archie 62.8.1 Fix 2): uploads are lossless 16 kHz FLAC.
@Suite struct FLACEncoderTests {
    static func signals() -> [(String, [Int16])] {
        var rng: UInt64 = 1_291_1
        func noise() -> Double { rng = rng &* 6364136223846793005 &+ 1; return Double(rng >> 32) / Double(UInt32.max) * 2 - 1 }
        let voice = (0..<48_017).map { i -> Int16 in
            let t = Double(i) / 16_000
            return Int16(clamping: Int(9_000 * sin(2 * .pi * 180 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t)) + 300 * noise()))
        }
        return [("one", [7]), ("four", [1, -1, 2, -2]), ("five", [0, 100, -100, 32767, -32768]),
                ("block-1", Array(voice.prefix(4_095))), ("block", Array(voice.prefix(4_096))),
                ("block+1", Array(voice.prefix(4_097))), ("voice-3s", voice),
                ("silence", [Int16](repeating: 0, count: 9_000)),
                ("extremes", (0..<5_000).map { $0 % 2 == 0 ? Int16.max : Int16.min }),
                ("noise", (0..<20_000).map { _ in Int16(clamping: Int(noise() * 32_767)) })]
    }

    @Test func roundTripsBitExactThroughAppleDecoder() throws {
        for (name, samples) in Self.signals() {
            let flac = try #require(FLACEncoder.encode(samples, sampleRate: 16_000))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("flac-\(UUID().uuidString).flac")
            try flac.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
            #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1, "\(name)")
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count + 16)))
            try file.read(into: buffer)
            let decoded = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
            #expect(decoded == samples, "\(name)")
            #expect(UploadBody.decode(flac) == samples, "\(name) test decoder")
        }
        print("P GREEN flac_apple_decoder_bit_exact signals=\(Self.signals().count)")
    }

    @Test func uploadIsFLACWithWAVFallback() {
        let voice = Self.signals().first { $0.0 == "voice-3s" }!.1
        let body = FLACEncoder.upload16k(voice)
        let wav = WAVEncoder.encode(samples: voice, sampleRate: 16_000)
        #expect(FLACEncoder.fileType(body) == ("audio.flac", "audio/flac"))
        #expect(FLACEncoder.fileType(wav) == ("audio.wav", "audio/wav"))
        #expect(FLACEncoder.upload16k([]) == WAVEncoder.encode(samples: [], sampleRate: 16_000))
        #expect(FLACEncoder.encode([1, 2], sampleRate: 11_025) == nil)
        print("P GREEN flac_upload bytes=\(body.count) wav_bytes=\(wav.count)")
        #expect(body.count < wav.count)
    }
}
