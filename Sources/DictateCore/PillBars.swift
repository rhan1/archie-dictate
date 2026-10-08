import Foundation

/// Wispr's persistent dB floor and 150 ms arithmetic-mean delivery.
public struct WisprLevel: Sendable {
    public static let batchSeconds = 0.150
    public private(set) var floorDB: Double = 0
    private var pending: [Double] = []
    private var nextBatch: Double?

    public init() {}

    public static func db(samples: [Float]) -> Double {
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        return 20 * log10(rms + 1e-10)
    }

    public mutating func level(db: Double) -> Double {
        if db < floorDB { floorDB = max(-60, db) }
        return max(0, min(1, (db - floorDB) / 20))
    }

    public mutating func append(db: Double, at time: Double) {
        pending.append(level(db: db))
        if nextBatch == nil { nextBatch = time + Self.batchSeconds }
    }

    /// Empty intervals send nothing, so the renderer retains its target.
    public mutating func batch(at time: Double) -> Double? {
        guard let deadline = nextBatch, time + 1e-12 >= deadline else { return nil }
        nextBatch = deadline + (floor(max(0, time - deadline) / Self.batchSeconds + 1e-12) + 1) * Self.batchSeconds
        guard !pending.isEmpty else { return nil }
        let mean = pending.reduce(0, +) / Double(pending.count)
        pending.removeAll(keepingCapacity: true)
        return mean
    }

    /// Capture boundaries discard pending delivery, never the adaptive floor.
    public mutating func clearBatch() {
        pending.removeAll(keepingCapacity: true)
        nextBatch = nil
    }
}

/// Normal-dictation waveform: shared quantized audio scale and staggered CSS motion.
public struct PillBars: Sendable {
    public static let count = 10
    public static let idleHeight: Double = 2
    public static let peakHeight: Double = 2 * 5 * (191.0 / 192) * 1.5
    public static let delays: [Double] = [0, 0.1, 0.2, 0.3, 0.4, -0.5, -0.4, -0.3, -0.2, -0.1]
    private static let keyframes: [(Double, Double)] = [(0, 1), (0.2, 1.2), (0.4, 1.5), (0.8, 1.1), (0.9, 1.3), (1, 1)]
    public private(set) var smoothed: Double = 0
    private var target: Double = 0

    public init() {}
    public mutating func push(level: Double) { target = max(0, min(1, level)) }
    public mutating func tick() { smoothed = floor(100 * (0.85 * smoothed + 0.15 * target)) / 100 }
    public mutating func reset() { smoothed = 0; target = 0 }

    public static func profile(_ i: Int) -> Double { max(0, 1 - pow(abs(4.5 - Double(i)), 2) / 48) }

    /// Solve the Bezier x coordinate before evaluating y (CSS ease-in-out).
    private static func ease(_ progress: Double) -> Double {
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<50 {
            let t = (lo + hi) / 2, u = 1 - t
            let x = 3 * u * u * t * 0.42 + 3 * u * t * t * 0.58 + t * t * t
            if x < progress { lo = t } else { hi = t }
        }
        let t = (lo + hi) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }

    public static func multiplier(at time: Double, delay: Double = 0) -> Double {
        let elapsed = time - delay
        guard elapsed >= 0 else { return 1 }
        let phase = elapsed - floor(elapsed)
        for k in 1..<keyframes.count where phase <= keyframes[k].0 {
            let (t0, v0) = keyframes[k - 1], (t1, v1) = keyframes[k]
            return v0 + (v1 - v0) * ease((phase - t0) / (t1 - t0))
        }
        return 1
    }

    /// Pure presentation lookup; time is seconds since recording went live.
    public func heights(at time: Double) -> [Double] {
        let scale = max(1, 5 * smoothed)
        return (0..<Self.count).map { 2 * scale * Self.profile($0) * Self.multiplier(at: time, delay: Self.delays[$0]) }
    }
}
