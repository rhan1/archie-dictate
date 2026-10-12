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
        /// v1.8: the headset gave up but the built-in was not fresh, so no fallback was taken
        /// (a dead built-in cannot be a fallback; the health clock decides what happens next).
        public var fallbackRefused = false
    }
    /// A 24 kHz batch whose peak is below this is digital silence (an eSCO drop injects zeros).
    public static let silencePeak: Float = 1e-4
    public static let takeoverSignal: TimeInterval = 0.15
    public static let fallbackAfter: TimeInterval = 1.5
    public static let switchbackAfter: TimeInterval = 0.5
    public static let restartAfter: TimeInterval = 0.7
    /// No headset buffer at all for this long while it carries (IO stopped, not zeros):
    /// longer than `switchbackAfter` because Bluetooth timestamps trail the built-in's.
    public static let headsetStaleAfter: TimeInterval = 1.0
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
    /// v1.8: built-in frames fed while in `.fallback` (bt-proof: `builtin_frames_after_fallback`).
    public private(set) var builtinFramesAfterFallback = 0
    /// H2: nil until a restart was requested, then whether the headset delivered signal after it.
    public private(set) var restart: HeadsetRestartState?
    private var recordingStart: TimeInterval?
    private var tapTime: TimeInterval?
    private var fedThrough: TimeInterval?
    /// The built-in engine is still running and can carry the dictation again.
    private var builtinAlive = false
    /// The default input is a Bluetooth headset: its digital silence is watched (H1/H2).
    private var bluetooth = false
    private var fallbackReason = "headset_digital_silence"
    private var firstHeadsetTime: TimeInterval?
    private var lastHeadsetEnd: TimeInterval?
    /// The headset delivered ≥ `takeoverSignal` of signal this dictation (its link works).
    private var headsetHadSignal = false
    /// The last switchback was for a headset that stopped delivering (a recovery gap, not
    /// zeros): a headset that returns with signal may take over again.
    private var staleSwitchback = false
    private var headsetSignalFrames = 0
    private var headsetSilentFrames = 0
    private var fallbackRefusedNoted = false
    public init() {}

    /// Timeline reason: a skip, a fallback, or a bridge whose built-in engine delivered no audio.
    public var reason: String? {
        if let skipReason { return skipReason }
        if bridgeSource == "builtin_fallback" { return fallbackReason }
        return bridgeSource == "builtin" && builtinFrames == 0 ? "builtin_no_audio" : nil
    }

    public mutating func start(defaultInput: DefaultInput, hasBuiltin: Bool,
                               epoch token: CaptureEpoch = CaptureEpoch()) {
        self = CaptureBridge()
        epoch = token
        if defaultInput == .builtin { skipReason = "default_builtin" }
        else if defaultInput != .bluetooth { skipReason = "not_bluetooth" }
        else if !hasBuiltin { skipReason = "no_builtin" }
        bluetooth = defaultInput == .bluetooth
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
    /// `builtinFresh` (v1.8): the built-in delivered recently with signal (CaptureHealth); a
    /// fallback or switchback to a built-in that is not fresh is refused.
    public mutating func buffer(source: Source, at time: TimeInterval, frames: Int,
                                arrivedAt: TimeInterval? = nil, epoch token: CaptureEpoch? = nil,
                                peak: Float = 1, builtinFresh: Bool = true) -> Decision {
        if let token, token !== epoch { return Decision() }
        guard state != .off, frames > 0 else { return Decision() }
        var result = Decision()
        if source == .headset, bluetooth { arbitrate(&result, at: time, frames: frames,
                                                     arrivedAt: arrivedAt, peak: peak, builtinFresh: builtinFresh) }
        let end = time + Double(frames) / Self.rate
        if source == .builtin, state == .builtinOnly, builtinFresh, let first = firstHeadsetTime, end - first >= Self.fallbackAfter {
            fallBack(&result)
        }
        // A headset that stops delivering buffers altogether (IO stopped, not zeros).
        if source == .builtin, canSwitchBack, builtinFresh, let last = lastHeadsetEnd, end - last > Self.headsetStaleAfter {
            switchBack(&result)
            staleSwitchback = true
            return result    // the owner replays this buffer from standby, after the frames it missed
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
            if source == .builtin, state == .fallback, recordingStart != nil { builtinFramesAfterFallback += accepted }
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
                                    arrivedAt: TimeInterval?, peak: Float, builtinFresh: Bool) {
        if firstHeadsetTime == nil { firstHeadsetTime = time }
        lastHeadsetEnd = time + Double(frames) / Self.rate
        if peak >= Self.silencePeak {
            headsetSignalFrames += frames
            headsetSilentFrames = 0
        } else {
            headsetSilentFrames += frames
            headsetSignalFrames = 0
        }
        let signal = Double(headsetSignalFrames) / Self.rate
        let silent = Double(headsetSilentFrames) / Self.rate
        if signal >= Self.takeoverSignal { headsetHadSignal = true }
        if signal >= Self.takeoverSignal, restart?.restarted == true { restart?.signalAfter = true }
        switch state {
        case .builtinOnly where bridgeSource != "none":
            if signal >= Self.takeoverSignal {
                state = .switched
                result.releaseBuiltin = true
                if let tap = tapTime {
                    bridgeMs = max(0, Int((((arrivedAt ?? time) - tap) * 1000).rounded()))
                }
            } else if let first = firstHeadsetTime,
                      time + Double(frames) / Self.rate - first >= Self.fallbackAfter {
                if builtinFresh { fallBack(&result) }
                else if !fallbackRefusedNoted { fallbackRefusedNoted = true; result.fallbackRefused = true }
            }
        case .switched where builtinAlive && silent > Self.switchbackAfter:
            if builtinFresh { switchBack(&result) }
            else if !fallbackRefusedNoted { fallbackRefusedNoted = true; result.fallbackRefused = true }
        case .fallback where staleSwitchback && signal >= Self.takeoverSignal:
            state = .switched                    // the recovered headset carries again
            staleSwitchback = false
        default: break
        }
        // The one restart runs while the built-in carries; with nothing else to carry, only
        // for a link that never delivered signal (a mid-dictation pause must not be cut).
        if silent >= Self.restartAfter, restart == nil,
           builtinAlive ? state != .switched : !headsetHadSignal {
            restart = HeadsetRestartState()
            result.restartHeadset = true
        }
    }

    private mutating func fallBack(_ result: inout Decision) {
        state = .fallback
        bridgeSource = "builtin_fallback"
        result.event = .fallback
    }

    private mutating func switchBack(_ result: inout Decision) {
        state = .fallback
        staleSwitchback = false
        switchbacks += 1
        result.event = .switchback
    }

    /// The headset engine failed for good. Returns the event when the built-in carries on
    /// (nil: nothing else can carry the dictation).
    public mutating func headsetFailed() -> Event? {
        guard builtinAlive else { return nil }
        var result = Decision()
        switch state {
        case .builtinOnly:
            fallbackReason = "headset_engine_failed"
            fallBack(&result)
        case .switched: switchBack(&result)
        case .fallback: return .fallback
        case .off: return nil
        }
        return result.event
    }

    /// v1.8 (L2): the health clock found the carrying built-in dead or transport-silent and the
    /// headset fresh with signal: the headset carries (either direction; `.fallback` no longer latches).
    public mutating func takeOver() {
        guard state == .builtinOnly || state == .fallback else { return }
        state = .switched
        staleSwitchback = false
        if bridgeMs == nil, let tap = tapTime, let last = lastHeadsetEnd { bridgeMs = max(0, Int(((last - tap) * 1000).rounded())) }
    }

    /// v1.8 (L2): the carrying headset went stale or transport-silent on the health clock and a
    /// fresh built-in takes over. A stale (not zero) headset may take over again when it returns.
    public mutating func headsetStalled(stale: Bool) {
        guard canSwitchBack else { return }
        var result = Decision()
        switchBack(&result)
        staleSwitchback = stale
    }

    /// v1.8: the built-in died mid-dictation (stale, drift, device lost). Only its liveness
    /// changes: the carrier changes only through `takeOver()` to a source the health clock
    /// found fresh with signal (otherwise the deadline ends the dictation).
    public mutating func builtinDied() {
        builtinAlive = false
    }
    public var builtinIsAlive: Bool { builtinAlive }

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
    public mutating func headsetRestarted(started: Bool = true) {
        restart?.restarted = started
        restart?.failed = !started
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
        restart = nil
        switchbacks = 0
        staleSwitchback = false
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
    public var failed = false
    public var signalAfter = false
    public var result: String { failed ? "failed" : signalAfter ? "signal" : "still_silent" }
}
