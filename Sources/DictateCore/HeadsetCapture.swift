import Foundation

/// v1.12 (L3): which client captures the headset. `engine` (default) is the AVAudioEngine input
/// node that follows the default device (v1.0–v1.11); `auhal` is `HeadsetCaptureUnit`, an
/// explicit-device, input-only AUHAL bound to the headset's UID (the mirror of the built-in's
/// `BuiltinCaptureUnit`). The arm is chosen per process for tomorrow's A/B (GPT-6 review §B);
/// never both at once.
public enum HeadsetBackend: String, Sendable, CaseIterable {
    case engine, auhal

    /// `DICTATE_HEADSET_BACKEND=auhal|engine`; anything else (or unset) is `engine`.
    public static func choose(environment: [String: String] = ProcessInfo.processInfo.environment) -> HeadsetBackend {
        environment["DICTATE_HEADSET_BACKEND"].flatMap { HeadsetBackend(rawValue: $0.lowercased()) } ?? .engine
    }
}

/// What a headset capture client reports besides frames. Every one is an ordinary state
/// transition (review §A.3): the recorder decides, the unit never retries on its own.
public enum HeadsetCaptureEvent: Equatable, Sendable {
    /// IO started on `deviceUID` at the hardware format (generation 1 at start).
    case started(deviceUID: String, sampleRate: Double, channels: Int)
    /// The device's stream format changed while running (A2DP→HFP: 44.1 kHz → 16 kHz); the unit
    /// rebuilt its converter for the new rate. `generation` counts formats seen this start.
    case formatChanged(generation: Int, sampleRate: Double, channels: Int)
    /// The rate read back as invalid (0 Hz, as an idle HFP device reports): no frames until a
    /// valid format arrives.
    case formatInvalid(generation: Int)
    /// The bound device disappeared or stopped being alive.
    case deviceLost
    /// No IO callback for `HeadsetCaptureUnit.callbackStall` while started.
    case callbacksStopped
    /// The converter could not be built or failed on a buffer (those frames are dropped).
    case converterFailed
    /// Teardown finished (stop → uninitialize → dispose each attempted).
    case stopped
}

/// v1.12 (L3): the headset capture client behind `headset_backend=auhal` (tests inject a fake).
/// Frames are 24 kHz mono Float with host-clock start times, delivered on the unit's worker queue.
public protocol HeadsetCapture: AnyObject {
    var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)? { get set }
    var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)? { get set }
    /// Binds the device with this UID (input element only, output disabled) and starts IO at its
    /// hardware rate. Synchronous; throws with the failing step.
    func start(deviceUID: String, epoch: CaptureEpoch) throws
    /// Idempotent; also after a partial start. Returns when the hardware is released.
    func stop()
    /// Stops only if the unit is still running for `epoch`.
    func stop(epoch: CaptureEpoch)
    /// IO started and not stopped (callbacks may still have ceased: see `lastCallbackTime`).
    var isRunning: Bool { get }
    var lastCallbackTime: TimeInterval? { get }
    /// Formats seen since the last start (1 = the start format).
    var formatGeneration: Int { get }
    /// IO callbacks and kept-frame counts since the last start.
    var counters: SourceCounters { get }
    /// Timeline value: `auhal`.
    var backend: String { get }
}

/// Per-source counts for the A/B instrumentation: actual IO callbacks, converted frames, digital
/// zeros and the RMS of everything delivered. Counts only — never audio.
public struct SourceCounters: Equatable, Sendable {
    public private(set) var callbacks = 0
    public private(set) var frames = 0
    public private(set) var zeros = 0
    private var sumSquares: Double = 0

    public init() {}

    /// One IO callback (AUHAL input proc, or an AVAudioEngine tap block).
    public mutating func callback() { callbacks += 1 }

    /// Frames delivered at 24 kHz.
    public mutating func frames(_ samples: [Float]) {
        frames += samples.count
        for sample in samples {
            if sample == 0 { zeros += 1 }
            sumSquares += Double(sample) * Double(sample)
        }
    }

    /// RMS of all delivered frames in dBFS (nil: none).
    public var rmsDBFS: Double? {
        guard frames > 0 else { return nil }
        let rms = (sumSquares / Double(frames)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }
}

/// v1.12 (L3): the session line's A/B instrumentation, identical in both arms:
/// `headset_backend=engine route_uid=… fmt_epochs=1:44100Hz/1ch@-412,2:16000Hz/1ch@180
/// io_callbacks=builtin:N,headset:N frames=builtin:N,headset:N zeros=builtin:N,headset:N
/// rms_dbfs=builtin:-31.2,headset:-27.9 takeover_ms=1106 fallback_ms=-`. Times are ms from
/// the recording boundary (negative = during prewarm).
public struct CaptureInstrumentation: Equatable, Sendable {
    public struct FormatEpoch: Equatable, Sendable {
        public var generation: Int
        public var sampleRate: Double
        public var channels: Int
        /// Host-clock time the format was first seen.
        public var at: TimeInterval
    }
    public var backend: HeadsetBackend
    public var routeUID: String?
    public private(set) var formatEpochs: [FormatEpoch] = []
    public private(set) var builtin = SourceCounters()
    public private(set) var headset = SourceCounters()
    /// Host-clock times of headset takeovers and built-in fallbacks/switchbacks.
    public private(set) var takeovers: [TimeInterval] = []
    public private(set) var fallbacks: [TimeInterval] = []
    /// At most this many epochs are listed (a notification storm is counted, not printed).
    public static let maxEpochs = 8
    public private(set) var epochsDropped = 0

    public init(backend: HeadsetBackend = .engine) { self.backend = backend }

    public mutating func callback(_ source: CaptureBridge.Source) {
        if source == .builtin { builtin.callback() } else { headset.callback() }
    }
    public mutating func frames(_ source: CaptureBridge.Source, _ samples: [Float]) {
        if source == .builtin { builtin.frames(samples) } else { headset.frames(samples) }
    }
    /// The headset's format at host time `at`: recorded only when it differs from the last epoch.
    public mutating func format(sampleRate: Double, channels: Int, at: TimeInterval) {
        if let last = formatEpochs.last, last.sampleRate == sampleRate, last.channels == channels { return }
        guard formatEpochs.count < Self.maxEpochs else { epochsDropped += 1; return }
        formatEpochs.append(FormatEpoch(generation: formatEpochs.count + 1 + epochsDropped,
                                        sampleRate: sampleRate, channels: channels, at: at))
    }
    public mutating func takeover(at time: TimeInterval) { if takeovers.count < Self.maxEpochs { takeovers.append(time) } }
    public mutating func fallback(at time: TimeInterval) { if fallbacks.count < Self.maxEpochs { fallbacks.append(time) } }

    /// Times render as ms from `boundary` (the recording boundary; nil → from the first epoch).
    public func note(boundary: TimeInterval?) -> String {
        let origin = boundary ?? formatEpochs.first?.at ?? 0
        func ms(_ t: TimeInterval) -> Int { Int(((t - origin) * 1000).rounded()) }
        func list(_ values: [TimeInterval]) -> String { values.isEmpty ? "-" : values.map { String(ms($0)) }.joined(separator: ",") }
        func db(_ value: Double?) -> String {
            guard let value else { return "-" }
            return value.isFinite ? String(format: "%.1f", value) : "-inf"
        }
        let epochs = formatEpochs.isEmpty ? "-" : formatEpochs.map {
            "\($0.generation):\(Int($0.sampleRate))Hz/\($0.channels)ch@\(ms($0.at))"
        }.joined(separator: ",") + (epochsDropped > 0 ? ",+\(epochsDropped)" : "")
        return "headset_backend=\(backend.rawValue) route_uid=\(routeUID ?? "-") fmt_epochs=\(epochs)"
            + " io_callbacks=builtin:\(builtin.callbacks),headset:\(headset.callbacks)"
            + " frames=builtin:\(builtin.frames),headset:\(headset.frames)"
            + " zeros=builtin:\(builtin.zeros),headset:\(headset.zeros)"
            + " rms_dbfs=builtin:\(db(builtin.rmsDBFS)),headset:\(db(headset.rmsDBFS))"
            + " takeover_ms=\(list(takeovers)) fallback_ms=\(list(fallbacks))"
    }
}
