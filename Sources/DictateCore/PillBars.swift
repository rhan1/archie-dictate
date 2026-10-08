import Foundation

/// Mic level for the pill. Speech on a Bluetooth headset (HFP, 16 kHz) sits
/// well below full scale, so a raw dB map looked like whispering (Raza, 01:1x).
/// Map −48 dBFS → idle and −18 dBFS → full, linear in dB, after a slow auto
/// gain that lifts the running speech peak 8 dB PAST full (≤ +18 dB): ordinary
/// speech runs ~10 dB under its peak, so it lands at ~85 % and peaks cap at 100 %.
public struct LevelMeter: Sendable {
    public static let floorDB: Float = -48
    public static let fullDB: Float = -18
    public static let maxGainDB: Float = 18
    public static let headroomDB: Float = 8
    /// Below this the input is treated as silence and never amplified.
    public static let gateDB: Float = -55
    /// How fast the remembered peak falls (dB per second).
    public static let peakDecayDBPerSecond: Float = 4

    /// Starts at the gate so the FIRST word sets the gain (instant attack), not ~3 s of decay.
    private var peakDB: Float = LevelMeter.gateDB

    public init() {}

    /// 0…1 for one chunk of audio lasting `seconds`.
    public mutating func level(rms: Float, seconds: Double) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        guard db > Self.gateDB else { return 0 }
        peakDB = max(db, peakDB - Self.peakDecayDBPerSecond * Float(seconds))
        let gain = min(Self.maxGainDB, max(0, Self.fullDB + Self.headroomDB - peakDB))
        return min(1, max(0, (db + gain - Self.floorDB) / (Self.fullDB - Self.floorDB)))
    }
}

/// The pill's bars as numbers: one smoothed level (attack ~50 ms, decay
/// ~250 ms at 30 fps) times a mild per-bar variation. Bars only change height.
public struct PillBars: Sendable {
    public static let count = 10
    public static let idleHeight: Double = 2
    public static let peakHeight: Double = 16
    public static let attack: Double = 0.48
    public static let decay: Double = 0.124

    public private(set) var smoothed: Double = 0
    private var target: Double = 0
    private var phase: Double = 0
    private let speed: [Double] = (0..<PillBars.count).map { 2.1 + Double(($0 * 7) % 5) * 0.37 }
    private let offset: [Double] = (0..<PillBars.count).map { Double(($0 * 3) % 7) * 0.9 }

    public init() {}

    public mutating func push(level: Double) { target = max(0, min(1, level)) }

    /// One 30 fps frame.
    public mutating func tick() {
        phase += 1.0 / 30.0
        smoothed += (target - smoothed) * (target > smoothed ? Self.attack : Self.decay)
    }

    public mutating func reset() { smoothed = 0; target = 0 }

    /// Per-bar variation 0.78…1.0 and a gentle centre bias (outer bars ≥ 0.88)
    /// keep them from moving in lockstep without shrinking the overall motion.
    public func height(_ i: Int) -> Double {
        let variation = 0.78 + 0.22 * (0.5 + 0.5 * sin(phase * speed[i] + offset[i]))
        let centre = 1 - abs(Double(i) - Double(Self.count - 1) / 2) / Double(Self.count) * 0.25
        return Self.idleHeight + (Self.peakHeight - Self.idleHeight) * smoothed * variation * centre
    }

    public var heights: [Double] { (0..<Self.count).map(height) }
}
