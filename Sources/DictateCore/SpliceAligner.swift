import Foundation

/// v1.13 (L3): one-shot alignment of the headset's content clock to the built-in's.
///
/// The bridge splices the two sources on host-clock timestamps. A timestamp says when a buffer reached
/// the HAL, not when its sound was in the room: a Bluetooth headset's frames carry the voice link's and
/// the codec's delay, the built-in's almost none. Spliced on timestamps alone, a takeover repeats the
/// last `lag` of speech and a switchback drops it — run 1 of the 10-13 A/B garbled "so for" across a
/// takeover/switchback/takeover at 910/1924/3353 ms, run 2 "draft" → "drop" across its 2318 ms
/// takeover. Before the first takeover, while the built-in carries and the headset already hears the
/// speaker, the two energy envelopes (5 ms bins: coarser than pitch pulses, finer than the 10 ms the
/// splice may err) are cross-correlated over the last `window`; a clear
/// peak gives the lag, and from then on the headset's timestamps are shifted onto the built-in's clock.
/// No clear peak (flat or unrelated envelopes): no shift — the v1.12 timestamp splice.
public enum SpliceAligner {
    public static let rate = 24_000.0
    /// Envelope resolution (5 ms).
    public static let binFrames = 120
    static let bin = Double(binFrames) / rate
    /// Headset audio compared (its most recent part).
    public static let window: TimeInterval = 0.3
    /// Lags considered: the headset trails by up to `maxLag`, or leads by up to `maxLead` (a Bluetooth
    /// input does not physically lead the built-in; the small lead covers timestamp jitter). The headset
    /// window ends `maxLead` before its newest frame so every candidate has built-in audio to meet.
    public static let maxLag: TimeInterval = 0.25
    public static let maxLead: TimeInterval = 0.03
    /// The window must hold this much headset signal (bins above a tenth of its loudest) to time anything.
    public static let minSignal: TimeInterval = 0.1
    /// Pearson correlation of the envelopes the peak must reach.
    public static let minCorrelation = 0.6
    /// The headset window must move: an envelope this flat (std/mean) carries no timing.
    public static let minContrast = 0.25
    /// … and span an onset: loudest bin over the quietest at least this (20 dB) — a steady tone or a
    /// steady noise has no edge to time.
    public static let minRange = 10.0
    /// The peak must stand out: the best correlation more than `uniqueBeyond` away is at least this much
    /// lower (a periodic envelope has many equal peaks and gives no estimate).
    public static let minMargin = 0.1
    public static let uniqueBeyond: TimeInterval = 0.03
    /// Share of the lag candidates that must have built-in audio to meet (early in a dictation the
    /// largest lags cannot yet).
    public static let minCoverage = 0.6

    public struct Estimate: Equatable, Sendable {
        /// Seconds the headset's content trails its timestamps relative to the built-in's (negative: leads).
        public var lag: TimeInterval
        public var correlation: Double
    }

    /// Headset content at its timestamp T is the built-in's content at T − lag. `headsetStart` /
    /// `builtinStart` are the host times of each array's first frame (both contiguous).
    public static func estimate(headset: [Float], headsetStart: TimeInterval,
                                builtin: [Float], builtinStart: TimeInterval) -> Estimate? {
        let h = envelope(headset), b = envelope(builtin)
        let bins = Int((window / bin).rounded())
        guard h.count >= bins / 2, b.count >= bins / 2 else { return nil }
        let leadBins = Int((maxLead / bin).rounded())
        guard h.count > leadBins + bins / 2 else { return nil }
        let usable = h.prefix(h.count - leadBins)
        let hw = Array(usable.suffix(bins))
        let hwStart = headsetStart + Double(usable.count - hw.count) * bin
        let loudest = hw.max() ?? 0
        guard loudest > 0, Double(hw.filter { $0 > loudest * 0.1 }.count) * bin >= minSignal - 0.000_001,
              loudest >= (hw.min() ?? 0) * minRange else { return nil }
        let mean = hw.reduce(0, +) / Double(hw.count)
        let std = (hw.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(hw.count)).squareRoot()
        guard mean > 0, std / mean >= minContrast else { return nil }
        let maxBins = Int((maxLag / bin).rounded())
        var scores: [(lag: Int, c: Double)] = []
        for lagBins in -leadBins...maxBins {
            // Built-in bin for headset bin k: time hwStart + k bins − lag.
            let offset = (hwStart - Double(lagBins) * bin - builtinStart) / bin
            let first = Int(offset.rounded())
            guard first >= 0, first + hw.count <= b.count else { continue }
            scores.append((lagBins, pearson(hw, b[first..<(first + hw.count)])))
        }
        // Most candidates must have been evaluable, and some rival beyond `uniqueBeyond`: a missing rival
        // is not evidence of uniqueness (review #9).
        guard Double(scores.count) >= minCoverage * Double(leadBins + maxBins + 1),
              let top = scores.max(by: { $0.c < $1.c }), top.c >= minCorrelation else { return nil }
        let away = Int((uniqueBeyond / bin).rounded())
        let rivals = scores.filter { abs($0.lag - top.lag) > away }.map(\.c)
        guard let rival = rivals.max() else { return nil }
        guard top.c - rival >= minMargin else { return nil }
        return Estimate(lag: Double(top.lag) * bin, correlation: top.c)
    }

    static func envelope(_ frames: [Float]) -> [Double] {
        stride(from: 0, to: frames.count - binFrames + 1, by: binFrames).map { start in
            var sum = 0.0
            for i in start..<(start + binFrames) { sum += Double(frames[i]) * Double(frames[i]) }
            return (sum / Double(binFrames)).squareRoot()
        }
    }

    static func pearson(_ x: [Double], _ y: ArraySlice<Double>) -> Double {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my); sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my)
        }
        guard sxx > 0, syy > 0 else { return 0 }
        return sxy / (sxx * syy).squareRoot()
    }
}
