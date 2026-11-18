import Foundation

/// 1.29.11 (Archie 62.8.1 Fix 2): the 16 kHz mono speech Groq and Scribe
/// receive, losslessly compressed (≈ half the WAV bytes on a slow uplink).
/// In memory, pure Foundation: FLAC subset, fixed predictors, Rice residuals.
public enum FLACEncoder {
    static let blockSize = 4096

    /// FLAC when encodable, else the same samples as 16 kHz WAV.
    public static func upload16k(_ samples: [Int16]) -> Data {
        encode(samples, sampleRate: 16_000) ?? WAVEncoder.encode(samples: samples, sampleRate: 16_000)
    }

    /// Multipart filename and type for an upload body.
    public static func fileType(_ body: Data) -> (name: String, mime: String) {
        body.starts(with: Array("fLaC".utf8)) ? ("audio.flac", "audio/flac") : ("audio.wav", "audio/wav")
    }

    /// Mono 16-bit FLAC; nil for an empty input or a rate without a subset code.
    public static func encode(_ samples: [Int16], sampleRate: Int) -> Data? {
        let rateCodes = [8_000: 4, 16_000: 5, 22_050: 6, 24_000: 7, 32_000: 8, 44_100: 9, 48_000: 10]
        guard !samples.isEmpty, let rateCode = rateCodes[sampleRate] else { return nil }
        var out = BitWriter()
        out.bytes = Array("fLaC".utf8)
        out.put(1 << 7, 8); out.put(34, 24)                        // last block, STREAMINFO, length
        out.put(blockSize, 16); out.put(blockSize, 16); out.put(0, 24); out.put(0, 24)
        out.put(sampleRate, 20); out.put(0, 3); out.put(15, 5); out.put(samples.count, 36)
        for _ in 0..<16 { out.put(0, 8) }                           // MD5 unknown
        for (index, start) in stride(from: 0, to: samples.count, by: blockSize).enumerated() {
            let block = samples[start..<min(start + blockSize, samples.count)].map(Int.init)
            var frame = BitWriter()
            frame.put(0xFFF8, 16); frame.put(block.count == blockSize ? 12 : 7, 4); frame.put(rateCode, 4)
            frame.put(0, 4); frame.put(4, 3); frame.put(0, 1)       // mono, 16-bit
            frame.utf8(index)
            if block.count != blockSize { frame.put(block.count - 1, 16) }
            frame.put(crc8(frame.bytes), 8)
            subframe(block, into: &frame)
            frame.align()
            frame.put(crc16(frame.bytes), 16)
            out.bytes += frame.bytes
        }
        return Data(out.bytes)
    }

    /// FIXED subframe: the order (0…4) with the smallest residual, one Rice partition; VERBATIM if smaller.
    private static func subframe(_ x: [Int], into w: inout BitWriter) {
        func residual(_ order: Int, _ n: Int) -> Int {
            switch order {
            case 0: return x[n]
            case 1: return x[n] - x[n-1]
            case 2: return x[n] - 2*x[n-1] + x[n-2]
            case 3: return x[n] - 3*x[n-1] + 3*x[n-2] - x[n-3]
            default: return x[n] - 4*x[n-1] + 6*x[n-2] - 4*x[n-3] + x[n-4]
            }
        }
        let maxOrder = min(4, x.count)
        var cost = [Int](repeating: 0, count: maxOrder + 1)
        for n in maxOrder..<x.count { for o in 0...maxOrder { cost[o] += abs(residual(o, n)) } }
        let order = cost.indices.min { cost[$0] < cost[$1] }!
        let folded = (order..<x.count).map { n -> Int in let e = residual(order, n); return e >= 0 ? 2 * e : -2 * e - 1 }
        // Rice parameter near log2(mean), the cheapest of three.
        let mean = folded.reduce(0, +) / max(1, folded.count)
        let guess = mean > 0 ? Int.bitWidth - mean.leadingZeroBitCount - 1 : 0
        let (k, bits) = (max(0, guess - 1)...min(14, guess + 1)).map { k in
            (k, folded.reduce(folded.count * (k + 1)) { $0 + ($1 >> k) })
        }.min { $0.1 < $1.1 }!
        // A frame never grows past raw PCM (Apple's decoder rejects one that does): VERBATIM.
        guard 16 * order + 10 + bits < 16 * x.count else {
            w.put(0, 1); w.put(1, 6); w.put(0, 1)
            for sample in x { w.put(sample & 0xFFFF, 16) }
            return
        }
        w.put(0, 1); w.put(8 | order, 6); w.put(0, 1)
        for n in 0..<order { w.put(x[n] & 0xFFFF, 16) }
        w.put(0, 2); w.put(0, 4); w.put(k, 4)
        for u in folded { w.put(0, u >> k); w.put(1, 1); w.put(u & ((1 << k) - 1), k) }
    }

    static func crc8(_ bytes: [UInt8]) -> Int {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return Int(crc)
    }

    static func crc16(_ bytes: [UInt8]) -> Int {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return Int(crc)
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        private var pending: UInt64 = 0
        private var pendingBits = 0
        mutating func put(_ value: Int, _ bits: Int) {
            var left = bits
            while left > 0 {
                let take = min(left, 8 - pendingBits)
                left -= take
                pending = pending << UInt64(take) | UInt64((value >> left) & ((1 << take) - 1))
                pendingBits += take
                if pendingBits == 8 { bytes.append(UInt8(pending)); pending = 0; pendingBits = 0 }
            }
        }
        mutating func align() { if pendingBits > 0 { put(0, 8 - pendingBits) } }
        /// FLAC's UTF-8-style coded frame number.
        mutating func utf8(_ n: Int) {
            if n < 0x80 { put(n, 8); return }
            let tail = n < 0x800 ? 1 : n < 0x10000 ? 2 : n < 0x200000 ? 3 : 4
            let lead = [0xC0, 0xE0, 0xF0, 0xF8][tail - 1]
            put(lead | (n >> (6 * tail)), 8)
            for i in stride(from: tail - 1, through: 0, by: -1) { put(0x80 | ((n >> (6 * i)) & 0x3F), 8) }
        }
    }
}
