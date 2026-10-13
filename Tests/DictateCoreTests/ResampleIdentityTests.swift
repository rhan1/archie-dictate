import Foundation
import Testing
import DictateCore

/// v1.11: `resampleTo16k` precomputes its two phases' taps; its output must be bit-identical to
/// the v1.10 per-sample formula (kept here verbatim as the reference).
@Suite("ResampleIdentity")
struct ResampleIdentityTests {
    private func v110(_ pcm: [Int16]) -> [Int16] {
        guard !pcm.isEmpty else { return [] }
        return (0..<(pcm.count * 2 / 3)).map { output in
            let position = Double(output) * 1.5
            let center = Int(position)
            var sum = 0.0, weight = 0.0
            for input in (center - 15)...(center + 16) {
                let distance = Double(input) - position
                guard abs(distance) < 16 else { continue }
                let x = distance * (2.0 / 3.0)
                let sinc = abs(x) < 1e-10 ? 1 : sin(.pi * x) / (.pi * x)
                let coefficient = (2.0 / 3.0) * sinc * (0.5 + 0.5 * cos(.pi * distance / 16))
                sum += Double(pcm[min(pcm.count - 1, max(0, input))]) * coefficient
                weight += coefficient
            }
            return Int16(clamping: Int((sum / weight).rounded()))
        }
    }

    @Test func identicalToTheV110Formula() {
        var generator = SystemRandomNumberGenerator()
        for count in [0, 1, 2, 3, 7, 31, 32, 33, 1_200, 7_201] {
            let noise = (0..<count).map { _ in Int16.random(in: .min ... .max, using: &generator) }
            #expect(GroqChunkedTranscriber.resampleTo16k(noise) == v110(noise))
        }
        let tone = (0..<24_000).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
        let extremes = (0..<4_800).map { $0.isMultiple(of: 2) ? Int16.max : Int16.min }
        #expect(GroqChunkedTranscriber.resampleTo16k(tone) == v110(tone))
        #expect(GroqChunkedTranscriber.resampleTo16k(extremes) == v110(extremes))
    }
}
