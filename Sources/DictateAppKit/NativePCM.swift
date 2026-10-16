import AVFoundation
import DictateObjC
import Foundation

/// Native operations execute in Objective-C's catching frame. Swift callers
/// keep ordinary NSError and conversion status failures on the same error path.
enum NativePCM {
    static func invalid(_ reason: String) -> NSError {
        NSError(domain: "DictateNativeAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    static func format(_ common: AVAudioCommonFormat, rate: Double, channels: Int, interleaved: Bool) throws -> AVAudioFormat {
        guard channels > 0, channels <= 32 else { throw invalid("invalid PCM channels") }
        var error: NSError?
        guard let value = dictate_pcm_format(common, rate, AVAudioChannelCount(channels), interleaved, &error) else {
            throw error ?? invalid("PCM format unavailable")
        }
        return value
    }
    static func buffer(_ format: AVAudioFormat, capacity: Int) throws -> AVAudioPCMBuffer {
        guard capacity > 0, capacity <= 2_000_000 else { throw invalid("invalid PCM capacity") }
        var error: NSError?
        guard let value = dictate_pcm_buffer(format, AVAudioFrameCount(capacity), &error) else {
            throw error ?? invalid("PCM buffer unavailable")
        }
        return value
    }
    static func converter(from: AVAudioFormat, to: AVAudioFormat) throws -> AVAudioConverter {
        var error: NSError?
        guard let value = dictate_audio_converter(from, to, &error) else { throw error ?? invalid("converter unavailable") }
        return value
    }
    static func convert(_ converter: AVAudioConverter, to buffer: AVAudioPCMBuffer,
                        input: @escaping AVAudioConverterInputBlock) throws -> AVAudioConverterOutputStatus {
        var error: NSError?
        let status = dictate_convert_audio(converter, buffer, input, &error)
        if let error { throw error }
        guard status != .error else { throw invalid("PCM conversion failed") }
        return status
    }
}
