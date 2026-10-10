import Foundation

/// Buffer-boundary source arbitration. The owner serializes calls with PCM delivery;
/// timestamps are host-clock seconds and every frame is 24 kHz mono.
///
/// v1.7 (H1): the headset takes over only after `takeoverSignal` of consecutive frames
/// that are not digital silence. A Bluetooth link whose eSCO channel was dropped delivers
/// injected zeros; then the built-in keeps carrying the dictation.
public struct CaptureBridge {
    public enum Source: Sendable { case builtin, headset }
    public enum DefaultInput: Sendable { case builtin, bluetooth, other }
    /// `fallback`: the built-in carries the rest of the dictation; headset frames are ignored.
    public enum State: Equatable, Sendable { case off, builtinOnly, switched, fallback }
    public enum Event: Equatable, Sendable {
        /// No headset signal within `fallbackAfter` of its first buffer.
        case fallback
        /// The headset went digital-zero for longer than `switchbackAfter` mid-dictation.
        case switchback
    }
    public struct Decision: Equatable, Sendable {
        public var dropFrames: Int = 0
        public var framesToFeed: Int = 0
        /// Before the second tap, accepted frames go to the owner's pre-roll ring.
        public var framesToRing: Int = 0
        /// The headset took over from the built-in (it may be released).
        public var releaseBuiltin = false
        /// H2: the headset has been digitally silent long enough to restart it once.
        public var restartHeadset = false
        public var event: Event?
    }
    /// A 24 kHz batch whose peak is below this is digital silence (an eSCO drop injects zeros).
    public static let silencePeak: Float = 1e-4
    public static let takeoverSignal: TimeInterval = 0.15
    public static let fallbackAfter: TimeInterval = 1.5
    public static let switchbackAfter: TimeInterval = 0.5
    public static let restartAfter: TimeInterval = 0.7
    private static let rate = 24_000.0

    public private(set) var state: State = .off
    public private(set) var bridgeMs: Int?
    public private(set) var bridgeSource = "none"
    public private(set) var skipReason: String?
    public private(set) var epoch = CaptureEpoch()
    /// Second tap → first kept frames available (0 when the ring already held audio).
    public private(set) var firstKeptMs: Int?
    /// Built-in frames accepted (ring or dictation); 0 means the bridge carried nothing.
    public private(set) var builtinFrames = 0
    public private(set) var switchbacks = 0
    /// H2: nil until a restart was requested, then whether the headset delivered signal after it.
    public private(set) var restart: HeadsetRestartState?
    private var recordingStart: TimeInterval?
    private var tapTime: TimeInterval?
    private var fedThrough: TimeInterval?
    /// The built-in engine is still running and can carry the dictation again.
    private var builtinAlive = false
    private var firstHeadsetTime: TimeInterval?
    private var headsetSignalFrames = 0
    private var headsetSilentFrames = 0
    public init() {}

    /// Timeline reason: a skip, a fallback, or a bridge whose built-in engine delivered no audio.
    public var reason: String? {
        if let skipReason { return skipReason }
        if bridgeSource == "builtin_fallback" { return "headset_digital_silence" }
        return bridgeSource == "builtin" && builtinFrames == 0 ? "builtin_no_audio" : nil
    }

    public mutating func start(defaultInput: DefaultInput, hasBuiltin: Bool,
                               epoch token: CaptureEpoch = CaptureEpoch()) {
        self = CaptureBridge()
        epoch = token
        if defaultInput == .builtin { skipReason = "default_builtin" }
        else if defaultInput != .bluetooth { skipReason = "not_bluetooth" }
        else if !hasBuiltin { skipReason = "no_builtin" }
        if skipReason == nil { state = .builtinOnly; bridgeSource = "builtin"; builtinAlive = true }
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

    /// `peak` is the buffer's largest absolute sample; the default treats it as signal.
    public mutating func buffer(source: Source, at time: TimeInterval, frames: Int,
                                arrivedAt: TimeInterval? = nil, epoch token: CaptureEpoch? = nil,
                                peak: Float = 1) -> Decision {
        if let token, token !== epoch { return Decision() }
        guard state != .off, frames > 0 else { return Decision() }
        var result = Decision()
        if source == .headset, bridgeSource != "none" { arbitrate(&result, at: time, frames: frames,
                                                                  arrivedAt: arrivedAt, peak: peak) }
        if source == .builtin, state == .builtinOnly, let first = firstHeadsetTime,
           time + Double(frames) / Self.rate - first >= Self.fallbackAfter {
            fallBack(&result)
        }
        let feeds = (source == .builtin && (state == .builtinOnly || state == .fallback)) ||
                    (source == .headset && state == .switched)
        guard feeds else { return result }
        // Trim all samples before the recording boundary or already delivered by
        // either source. This also handles a whole overlapping headset buffer.
        let boundary = [recordingStart, fedThrough].compactMap { $0 }.max()
        if let boundary {
            result.dropFrames = min(frames, max(0, Int(ceil((boundary - time) * Self.rate - 0.000001))))
        }
        let accepted = frames - result.dropFrames
        if accepted > 0 {
            fedThrough = max(boundary ?? time, time + Double(frames) / Self.rate)
            if source == .builtin { builtinFrames += accepted }
        }
        guard recordingStart != nil else { result.framesToRing = accepted; return result }
        result.framesToFeed = accepted
        if accepted > 0, firstKeptMs == nil, let tap = tapTime {
            firstKeptMs = max(0, Int((((arrivedAt ?? time) - tap) * 1000).rounded()))
        }
        return result
    }

    /// Headset content decides takeover, fallback, switchback and the one restart.
    private mutating func arbitrate(_ result: inout Decision, at time: TimeInterval, frames: Int,
                                    arrivedAt: TimeInterval?, peak: Float) {
        if firstHeadsetTime == nil { firstHeadsetTime = time }
        if peak >= Self.silencePeak {
            headsetSignalFrames += frames
            headsetSilentFrames = 0
        } else {
            headsetSilentFrames += frames
            headsetSignalFrames = 0
        }
        let signal = Double(headsetSignalFrames) / Self.rate
        let silent = Double(headsetSilentFrames) / Self.rate
        if signal >= Self.takeoverSignal, restart?.restarted == true { restart?.signalAfter = true }
        switch state {
        case .builtinOnly:
            if signal >= Self.takeoverSignal {
                state = .switched
                result.releaseBuiltin = true
                if let tap = tapTime {
                    bridgeMs = max(0, Int((((arrivedAt ?? time) - tap) * 1000).rounded()))
                }
            } else if let first = firstHeadsetTime,
                      time + Double(frames) / Self.rate - first >= Self.fallbackAfter {
                fallBack(&result)
            }
        case .switched where builtinAlive && silent > Self.switchbackAfter:
            state = .fallback
            switchbacks += 1
            result.event = .switchback
        default: break
        }
        if silent >= Self.restartAfter, builtinAlive, state != .switched, restart == nil {
            restart = HeadsetRestartState()
            result.restartHeadset = true
        }
    }

    private mutating func fallBack(_ result: inout Decision) {
        state = .fallback
        bridgeSource = "builtin_fallback"
        result.event = .fallback
    }

    /// The headset carries and the built-in could take over again.
    public var canSwitchBack: Bool { state == .switched && builtinAlive }
    public var fedThroughTime: TimeInterval? { fedThrough }
    public var isRecording: Bool { recordingStart != nil }

    /// Standby built-in frames that continue the dictation exactly at the switchback.
    public mutating func resumedBuiltin(frames: Int, through end: TimeInterval) {
        fedThrough = max(fedThrough ?? end, end)
        builtinFrames += frames
    }

    /// The owner restarted the headset engine (H2); later signal marks the retry a success.
    public mutating func headsetRestarted() {
        restart?.restarted = true
        headsetSignalFrames = 0
    }

    /// Returns the release effect only if the bridge still owns the built-in input.
    @discardableResult public mutating func cancel() -> Bool {
        let release = state == .builtinOnly || state == .fallback
        state = .off
        epoch = CaptureEpoch()
        recordingStart = nil
        tapTime = nil
        fedThrough = nil
        builtinAlive = false
        return release
    }

    /// Failure of the optional bridge never prevents normal headset capture.
    public mutating func builtinFailed() {
        builtinAlive = false
        switch state {
        case .builtinOnly:
            state = .switched
            bridgeSource = "none"
            skipReason = "builtin_start_failed"
        case .fallback:
            // Nothing else can carry the dictation: the headset, even silent, is the source again.
            state = .switched
            skipReason = "builtin_failed_after_fallback"
        default: break
        }
    }
}

/// H2: at most one clean headset restart per dictation; `result` is the timeline value.
public struct HeadsetRestartState: Equatable, Sendable {
    public var restarted = false
    public var signalAfter = false
    public var result: String { signalAfter ? "signal" : "still_silent" }
}
