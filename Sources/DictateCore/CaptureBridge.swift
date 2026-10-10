import Foundation

/// Buffer-boundary source arbitration. The owner serializes calls with PCM delivery;
/// timestamps are host-clock seconds and every frame is 24 kHz mono.
public struct CaptureBridge {
    public enum Source: Sendable { case builtin, headset }
    public enum DefaultInput: Sendable { case builtin, bluetooth, other }
    public enum State: Equatable, Sendable { case off, builtinOnly, switched }
    public struct Decision: Equatable, Sendable {
        public var dropFrames: Int = 0
        public var framesToFeed: Int = 0
        public var releaseBuiltin = false
    }
    public private(set) var state: State = .off
    public private(set) var bridgeMs: Int?
    public private(set) var bridgeSource = "none"
    public private(set) var skipReason: String?
    public private(set) var epoch = CaptureEpoch()
    private var recordingStart: TimeInterval?
    private var fedThrough: TimeInterval?
    public init() {}

    public mutating func start(defaultInput: DefaultInput, hasBuiltin: Bool,
                               epoch token: CaptureEpoch = CaptureEpoch()) {
        self = CaptureBridge()
        epoch = token
        if defaultInput == .builtin { skipReason = "default_builtin" }
        else if defaultInput != .bluetooth { skipReason = "not_bluetooth" }
        else if !hasBuiltin { skipReason = "no_builtin" }
        if skipReason == nil { state = .builtinOnly; bridgeSource = "builtin" }
        else { state = .switched }
    }

    /// Both sources discard pre-roll at the second tap, even when hardware startup
    /// is still in flight. A headset already flowing in prewarm needs no bridge.
    public mutating func recordingStarted(at time: TimeInterval) {
        recordingStart = time
        fedThrough = nil
        bridgeMs = state == .switched && bridgeSource == "builtin" ? 0 : nil
    }

    public mutating func buffer(source: Source, at time: TimeInterval, frames: Int,
                                arrivedAt: TimeInterval? = nil, epoch token: CaptureEpoch? = nil) -> Decision {
        if let token, token !== epoch { return Decision() }
        guard state != .off, frames > 0 else { return Decision() }
        var result = Decision()
        if source == .headset, state == .builtinOnly {
            state = .switched
            result.releaseBuiltin = true
            if let start = recordingStart {
                bridgeMs = max(0, Int((((arrivedAt ?? time) - start) * 1000).rounded()))
            }
        }
        guard let recordingStart,
              (source == .builtin && state == .builtinOnly) ||
              (source == .headset && state == .switched) else { return result }
        // Trim all samples before the recording boundary or already delivered by
        // either source. This also handles a whole overlapping headset buffer.
        let boundary = max(recordingStart, fedThrough ?? recordingStart)
        result.dropFrames = min(frames, max(0, Int(ceil((boundary - time) * 24_000 - 0.000001))))
        result.framesToFeed = frames - result.dropFrames
        if result.framesToFeed > 0 {
            fedThrough = max(boundary, time + Double(frames) / 24_000)
        }
        return result
    }

    /// Returns the release effect only if the bridge still owns the built-in input.
    @discardableResult public mutating func cancel() -> Bool {
        let release = state == .builtinOnly
        state = .off
        epoch = CaptureEpoch()
        recordingStart = nil
        fedThrough = nil
        return release
    }

    /// Failure of the optional bridge never prevents normal headset capture.
    public mutating func builtinFailed() {
        guard state == .builtinOnly else { return }
        state = .switched
        bridgeSource = "none"
        skipReason = "builtin_start_failed"
    }
}
