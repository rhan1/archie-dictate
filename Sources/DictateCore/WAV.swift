import Foundation

public enum WAVEncoder {
    /// Encodes interleaved samples as 16-bit little-endian PCM.
    public static func encode(samples: [Int16], sampleRate: Int = 16_000,
                              channels: Int = 1) -> Data {
        precondition(sampleRate > 0 && channels > 0 && channels <= Int(UInt16.max) / 2)
        precondition(sampleRate <= Int(UInt32.max) / (channels * 2))
        precondition(samples.count <= (Int(UInt32.max) - 36) / 2)
        let dataBytes = UInt32(samples.count * 2)
        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)
        func append16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                data.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        data.append(contentsOf: "RIFF".utf8)
        append32(36 + dataBytes)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(1)
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * channels * 2))
        append16(UInt16(channels * 2))
        append16(16)
        data.append(contentsOf: "data".utf8)
        append32(dataBytes)
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        return data
    }

    /// Uses symmetric endpoints: -1 maps to -32767; NaN maps to silence.
    public static func pcm16(from floats: [Float]) -> [Int16] {
        floats.map { value in
            guard !value.isNaN else { return 0 }
            return Int16((min(1, max(-1, value)) * 32767).rounded())
        }
    }
}

public enum AudioLevel {
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float(sqrt(sum / Double(samples.count)))
    }

    public static func normalized(rms: Float) -> Float {
        guard !rms.isNaN else { return 0 }
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (decibels + 50) / 50))
    }
}
