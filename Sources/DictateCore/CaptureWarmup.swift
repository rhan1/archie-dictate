import Foundation

/// Bluetooth headsets need ~1.6 s to switch to their mic profile. The engine is
/// therefore started on the FIRST ⌥ tap (pre-warm) and the pill shows WARMING
/// until real audio flows, so the user can see when it is actually listening.
public struct CaptureWarmup: Sendable {
    public enum Phase: Equatable, Sendable { case off, prewarming, warming, live }
    public enum Effect: Equatable, Sendable { case startEngine, stopEngine, showWarming, showLive }

    /// A pre-warm with no double-tap after this long is stopped silently
    /// (second press within the 350 ms window + a tap of up to 350 ms).
    public static let prewarmTimeout: TimeInterval = DoubleTapDetector.defaultWindow + DoubleTapDetector.defaultMaxHold

    public private(set) var phase: Phase = .off
    /// Second tap -> first audio buffer, in ms (0 when audio already flowed).
    public private(set) var warmMs: Int?
    private var buffersFlowing = false
    private var recordingStart: TimeInterval?

    public init() {}

    /// First clean ⌥ tap while idle.
    public mutating func firstTap() -> [Effect] {
        guard phase == .off else { return [] }
        phase = .prewarming
        buffersFlowing = false
        return [.startEngine]
    }

    /// The second tap (or the menu / ✓ path) started a dictation.
    public mutating func recordingStarted(at time: TimeInterval, engineRunning: Bool? = nil) -> [Effect] {
        recordingStart = time
        warmMs = nil
        var effects: [Effect] = []
        if !(engineRunning ?? (phase != .off)) {
            buffersFlowing = false
            effects.append(.startEngine)
        }
        if buffersFlowing {
            phase = .live
            warmMs = 0
            effects.append(.showLive)
        } else {
            phase = .warming
            effects.append(.showWarming)
        }
        return effects
    }

    /// Any audio buffer from the engine.
    public mutating func bufferArrived(at time: TimeInterval) -> [Effect] {
        buffersFlowing = true
        guard phase == .warming else { return [] }
        phase = .live
        if let start = recordingStart { warmMs = max(0, Int(((time - start) * 1000).rounded())) }
        return [.showLive]
    }

    /// The pre-warm timer fired: no double-tap came.
    public mutating func prewarmExpired() -> [Effect] {
        guard phase == .prewarming else { return [] }
        phase = .off
        buffersFlowing = false
        return [.stopEngine]
    }

    /// Dictation finished or cancelled; the engine is stopped by the caller.
    public mutating func stopped() {
        phase = .off
        buffersFlowing = false
        recordingStart = nil
    }
}
