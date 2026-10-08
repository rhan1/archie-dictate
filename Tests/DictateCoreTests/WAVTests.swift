import Foundation
import Testing
import DictateCore

@Suite("WAV")
struct WAVTests {
    private func integer(_ data: Data, _ offset: Int, _ count: Int) -> UInt32 {
        (0..<count).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }

    @Test func monoHeader() {
        let data = WAVEncoder.encode(samples: [1, -1, 0])
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(integer(data, 4, 4) == 42)
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[12..<16], as: UTF8.self) == "fmt ")
        #expect(integer(data, 16, 4) == 16)
        #expect(integer(data, 20, 2) == 1)
        #expect(integer(data, 22, 2) == 1)
        #expect(integer(data, 24, 4) == 16000)
        #expect(integer(data, 28, 4) == 32000)
        #expect(integer(data, 32, 2) == 2)
        #expect(integer(data, 34, 2) == 16)
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        #expect(integer(data, 40, 4) == 6)
    }
    @Test func totalSizeForOneSecond() {
        #expect(WAVEncoder.encode(samples: Array(repeating: 0, count: 16000)).count == 32044)
    }
    @Test func littleEndianSamples() {
        let data = WAVEncoder.encode(samples: [0x1234, -2, Int16.min, Int16.max])
        #expect(Array(data.dropFirst(44)) == [0x34, 0x12, 0xfe, 0xff, 0x00, 0x80, 0xff, 0x7f])
    }
    @Test func pcmClamping() {
        #expect(WAVEncoder.pcm16(from: [-2, -1, 0, 1, 2]) == [-32767, -32767, 0, 32767, 32767])
        #expect(WAVEncoder.pcm16(from: [.nan, -.infinity, .infinity]) == [0, -32767, 32767])
    }
    @Test func knownRMS() {
        #expect(AudioLevel.rms([]) == 0)
        #expect(AudioLevel.rms([1, -1, 1, -1]) == 1)
        #expect(AudioLevel.rms([0.5, -0.5]) == 0.5)
        #expect(abs(AudioLevel.rms([0, 1]) - Float(sqrt(0.5))) < 0.000001)
    }
    @Test func normalizedBounds() {
        #expect(AudioLevel.normalized(rms: 0) == 0)
        #expect(AudioLevel.normalized(rms: -1) == 0)
        #expect(AudioLevel.normalized(rms: 1) == 1)
        #expect(AudioLevel.normalized(rms: 10) == 1)
        #expect(abs(AudioLevel.normalized(rms: 0.1) - 0.6) < 0.000001)
    }
    @Test func emptyAudioHasHeaderOnly() {
        let data = WAVEncoder.encode(samples: [])
        #expect(data.count == 44)
        #expect(integer(data, 4, 4) == 36)
        #expect(integer(data, 40, 4) == 0)
    }
    @Test func stereoHeader() {
        let data = WAVEncoder.encode(samples: [1, 2], sampleRate: 48000, channels: 2)
        #expect(integer(data, 22, 2) == 2)
        #expect(integer(data, 24, 4) == 48000)
        #expect(integer(data, 28, 4) == 192000)
        #expect(integer(data, 32, 2) == 4)
    }
}

@Suite("Silence")
struct SilenceTests {
    @Test func zerosAndRoomHissAreSilent() {
        #expect(AudioLevel.isSilent([]))
        #expect(AudioLevel.isSilent([Float](repeating: 0, count: 16_000)))
        #expect(AudioLevel.isSilent([Float](repeating: 0.005, count: 16_000)))
    }

    @Test func anySpeechPeakIsNotSilent() {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[8_000] = -0.2
        #expect(!AudioLevel.isSilent(samples))
    }
}
