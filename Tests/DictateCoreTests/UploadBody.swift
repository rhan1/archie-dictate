import Foundation
import DictateCore

/// 1.29.11: uploads are FLAC. Fakes that read the uploaded PCM see it as the
/// same samples in a 16 kHz WAV (the decoder covers FLACEncoder's subset).
enum UploadBody {
    /// The multipart body with a FLAC file part replaced by its WAV twin.
    static func asWAV(_ body: Data) -> Data {
        guard let start = body.range(of: Data("fLaC".utf8))?.lowerBound,
              let end = body.range(of: Data("\r\n--".utf8), options: .backwards)?.lowerBound, end > start,
              let samples = decode(body.subdata(in: start..<end)) else { return body }
        var out = body.subdata(in: 0..<start)
        out.append(WAVEncoder.encode(samples: samples, sampleRate: 16_000))
        out.append(body.subdata(in: end..<body.count))
        return out
    }

    static func decode(_ flac: Data) -> [Int16]? {
        var r = BitReader(bytes: [UInt8](flac))
        guard r.read(32) == 0x664C_6143 else { return nil }
        var last = false
        while !last {
            last = r.read(1) == 1
            _ = r.read(7)
            r.skipBytes(r.read(24))
        }
        var out: [Int16] = []
        while r.remaining >= 16 {
            guard r.read(16) == 0xFFF8 else { return nil }
            let sizeCode = r.read(4); _ = r.read(4); _ = r.read(4); _ = r.read(3); _ = r.read(1)
            var lead = r.read(8), extra = 0
            while lead & 0x80 != 0 { extra += 1; lead <<= 1; lead &= 0xFF }
            if extra > 0 { for _ in 1..<extra { _ = r.read(8) } }
            let count = sizeCode == 12 ? 4096 : sizeCode == 7 ? r.read(16) + 1 : -1
            guard count > 0 else { return nil }
            _ = r.read(8)                                             // CRC-8
            _ = r.read(1)
            let type = r.read(6); _ = r.read(1)
            if type == 1 {                                            // VERBATIM
                out += (0..<count).map { _ in Int16(truncatingIfNeeded: r.read(16)) }
                r.align(); _ = r.read(16); continue
            }
            guard type & 0x38 == 8 else { return nil }
            let order = type & 7
            var x = (0..<order).map { _ in Int(Int16(truncatingIfNeeded: r.read(16))) }
            guard r.read(2) == 0, r.read(4) == 0 else { return nil }
            let k = r.read(4)
            for n in order..<count {
                var q = 0
                while r.read(1) == 0 { q += 1 }
                let u = q << k | r.read(k)
                let e = u & 1 == 0 ? u >> 1 : -(u >> 1) - 1
                let p: Int
                switch order {
                case 0: p = 0
                case 1: p = x[n-1]
                case 2: p = 2*x[n-1] - x[n-2]
                case 3: p = 3*x[n-1] - 3*x[n-2] + x[n-3]
                default: p = 4*x[n-1] - 6*x[n-2] + 4*x[n-3] - x[n-4]
                }
                x.append(p + e)
            }
            r.align()
            _ = r.read(16)                                            // CRC-16
            out += x.map { Int16(truncatingIfNeeded: $0) }
        }
        return out
    }

    struct BitReader {
        let bytes: [UInt8]
        var bit = 0
        var remaining: Int { bytes.count * 8 - bit }
        mutating func read(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                guard bit < bytes.count * 8 else { return v }
                v = v << 1 | Int(bytes[bit >> 3] >> (7 - UInt8(bit & 7)) & 1)
                bit += 1
            }
            return v
        }
        mutating func skipBytes(_ n: Int) { bit += n * 8 }
        mutating func align() { bit = (bit + 7) & ~7 }
    }
}
