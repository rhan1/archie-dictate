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
        /// Before the second tap, accepted frames go to the owner's pre-roll ring.
        public var framesToRing: Int = 0
        public var releaseBuiltin = false
    }
    public private(set) var state: State = .off
    public private(set) var bridgeMs: Int?
    public private(set) var bridgeSource = "none"
    public private(set) var skipReason: String?
    public private(set) var epoch = CaptureEpoch()
    /// Second tap → first kept frames available (0 when the ring already held audio).
    public private(set) var firstKeptMs: Int?
    /// Built-in frames accepted (ring or dictation); 0 means the bridge carried nothing.
    public private(set) var builtinFrames = 0
    private var recordingStart: TimeInterval?
    private var tapTime: TimeInterval?
    private var fedThrough: TimeInterval?
    public init() {}

    /// Timeline reason: a skip, or a bridge whose built-in engine delivered no audio.
    public var reason: String? {
        skipReason ?? (bridgeSource == "builtin" && builtinFrames == 0 ? "builtin_no_audio" : nil)
    }

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

    /// Both sources discard audio before `time − preRoll`, even when hardware startup
    /// is still in flight. A headset already flowing in prewarm needs no bridge.
    /// Ring frames already accepted stay the continuity point, so live buffers
    /// never duplicate kept pre-roll.
    public mutating func recordingStarted(at time: TimeInterval, preRoll: TimeInterval = 0,
                                          keptFrames: Int = 0) {
        recordingStart = time - preRoll
        tapTime = time
        firstKeptMs = keptFrames > 0 ? 0 : nil
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
            if let tap = tapTime {
                bridgeMs = max(0, Int((((arrivedAt ?? time) - tap) * 1000).rounded()))
            }
        }
        guard (source == .builtin && state == .builtinOnly) ||
              (source == .headset && state == .switched) else { return result }
        // Trim all samples before the recording boundary or already delivered by
        // either source. This also handles a whole overlapping headset buffer.
        let boundary = [recordingStart, fedThrough].compactMap { $0 }.max()
        if let boundary {
            result.dropFrames = min(frames, max(0, Int(ceil((boundary - time) * 24_000 - 0.000001))))
        }
        let accepted = frames - result.dropFrames
        if accepted > 0 {
            fedThrough = max(boundary ?? time, time + Double(frames) / 24_000)
            if source == .builtin { builtinFrames += accepted }
        }
        guard recordingStart != nil else { result.framesToRing = accepted; return result }
        result.framesToFeed = accepted
        if accepted > 0, firstKeptMs == nil, let tap = tapTime {
            firstKeptMs = max(0, Int((((arrivedAt ?? time) - tap) * 1000).rounded()))
        }
        return result
    }

    /// Returns the release effect only if the bridge still owns the built-in input.
    @discardableResult public mutating func cancel() -> Bool {
        let release = state == .builtinOnly
        state = .off
        epoch = CaptureEpoch()
        recordingStart = nil
        tapTime = nil
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
