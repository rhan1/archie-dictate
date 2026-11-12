import CryptoKit
import Foundation

/// 1.29.6 (D1a): optional format-change reporting and hardware format summary on `BuiltinCapture`.
/// Kept as a refined protocol so `BuiltinCapture.swift` and existing fakes remain unchanged.
public protocol BuiltinFormatChangeReporting: BuiltinCapture {
    var onFormatChange: ((CaptureEpoch) -> Void)? { get set }
    var hardwareFormatSummary: (sampleRate: Double, channels: Int)? { get }
}

/// 1.29.6 (D1a/D3): at most one built-in unit restart per 5.0 s window for a sole-builtin conversation.
/// A second failure inside the window is declined so `builtin_bind_failed` terminates the capture cleanly
/// instead of spinning.
public struct SoleBuiltinRestartPolicy: Equatable, Sendable {
    public static let window: TimeInterval = 5.0

    public enum Reason: String, Equatable, Sendable {
        case stale
        case drift
        case lost
        case format
    }

    public enum Verdict: Equatable, Sendable {
        case restart(Reason)
        case fail
    }

    public private(set) var lastRestartAt: TimeInterval?

    public init() {}

    public mutating func judge(reason: Reason, at now: TimeInterval) -> Verdict {
        if let last = lastRestartAt, now - last < Self.window {
            return .fail
        }
        lastRestartAt = now
        return .restart(reason)
    }

    public static func note(reason: Reason) -> String {
        "builtin_restart=1 reason=\(reason.rawValue)"
    }
}

/// 1.29.6 (D6): first-audio verdict reported once per built-in conversation capture attempt at `t0 + 1.0 s`.
public enum BuiltinFirstAudioVerdict: String, Equatable, Sendable {
    case ok
    case zeros
    case noBuffer = "no_buffer"

    public var note: String { "builtin_first_audio=\(rawValue)" }
}

/// 1.29.6 (D6): evaluates the first 1.0 s of a built-in conversation capture attempt in the Float domain
/// using `CaptureBridge.silencePeak` by reference. Route applies and relistens do not renew it.
public struct SoleBuiltinFirstAudio: Equatable, Sendable {
    public static let limit: TimeInterval = 1.0
    public static var silencePeak: Float { CaptureBridge.silencePeak }

    public private(set) var requestTime: TimeInterval?
    public private(set) var startReturnedAt: TimeInterval?
    public private(set) var startTimedOut: Bool = false
    public private(set) var totalBuffers: Int = 0
    public private(set) var aboveThresholdBuffers: Int = 0
    public private(set) var lastBufferAboveThreshold: Bool = false
    public private(set) var maxPeak: Float = 0
    public private(set) var verdict: BuiltinFirstAudioVerdict?

    public init() {}

    public mutating func startRequested(at time: TimeInterval) {
        guard verdict == nil, requestTime == nil else { return }
        requestTime = time
    }

    /// Records `t0` when the unit's `start(epoch:)` returns. Returns the `builtin_first_audio_clock` note
    /// once per attempt, or `nil` if already recorded or if start took at least `limit` (which settles as `.noBuffer` in `evaluate`).
    @discardableResult
    public mutating func startReturned(at time: TimeInterval) -> String? {
        guard verdict == nil, startReturnedAt == nil, !startTimedOut else { return nil }
        if let req = requestTime, time - req >= Self.limit {
            startTimedOut = true
            return nil
        }
        startReturnedAt = time
        let ms = Int((time * 1000).rounded())
        return "builtin_first_audio_clock start=\(ms)"
    }

    public var deadline: TimeInterval? {
        if let t0 = startReturnedAt { return t0 + Self.limit }
        if let req = requestTime { return req + Self.limit }
        return nil
    }

    public func isDue(at now: TimeInterval) -> Bool {
        guard verdict == nil else { return false }
        if startTimedOut { return true }
        guard let due = deadline else { return false }
        return now >= due
    }

    /// Serialized with `evaluate(at:)`. A buffer observed at or before `t0 + limit` counts.
    public mutating func observe(frames: [Float], at time: TimeInterval) {
        guard verdict == nil, !startTimedOut, let t0 = startReturnedAt, !frames.isEmpty else { return }
        guard time <= t0 + Self.limit else { return }
        let peak = frames.reduce(Float(0)) { max($0, abs($1)) }
        totalBuffers += 1
        if peak > maxPeak { maxPeak = peak }
        let above = peak >= Self.silencePeak
        if above { aboveThresholdBuffers += 1 }
        lastBufferAboveThreshold = above
    }

    /// Evaluates the verdict once when `now` reaches the deadline. Returns the verdict on the transition
    /// from `nil` to settled; subsequent calls return `nil`.
    @discardableResult
    public mutating func evaluate(at now: TimeInterval) -> BuiltinFirstAudioVerdict? {
        guard verdict == nil else { return nil }
        if startTimedOut {
            verdict = .noBuffer
            return .noBuffer
        }
        guard let t0 = startReturnedAt else {
            if let req = requestTime, now >= req + Self.limit {
                startTimedOut = true
                verdict = .noBuffer
                return .noBuffer
            }
            return nil
        }
        guard now >= t0 + Self.limit else { return nil }
        let decided: BuiltinFirstAudioVerdict
        if totalBuffers == 0 {
            decided = .noBuffer
        } else if aboveThresholdBuffers == 0 {
            decided = .zeros
        } else {
            decided = .ok
        }
        verdict = decided
        return decided
    }
}

/// 1.29.6 (D2/D4): built-in conversation route fingerprint and `route_fp` diagnostic formatting.
/// Hashes ONLY: built-in `(id, uid, rate, alive, channels)` + default output `(id, uid, alive)` + default input `(id, uid)`.
/// Output rate/streams and input rate/liveness/streams are excluded by construction.
public enum RouteFingerprint {
    /// Complete raw device snapshot before D2 field projection.
    public struct RawDeviceFacts: Equatable, Sendable {
        public var id: UInt32
        public var uid: String
        public var rate: Double
        public var alive: Bool
        public var inputChannels: UInt32
        public var outputChannels: UInt32

        public init(
            id: UInt32,
            uid: String,
            rate: Double = 48_000,
            alive: Bool = true,
            inputChannels: UInt32 = 0,
            outputChannels: UInt32 = 0
        ) {
            self.id = id
            self.uid = uid
            self.rate = rate
            self.alive = alive
            self.inputChannels = inputChannels
            self.outputChannels = outputChannels
        }
    }

    public struct BuiltinFacts: Equatable, Sendable {
        public var id: UInt32
        public var uid: String
        public var rate: Double
        public var alive: Bool
        public var channels: UInt32

        public init(id: UInt32, uid: String, rate: Double, alive: Bool, channels: UInt32) {
            self.id = id
            self.uid = uid
            self.rate = rate
            self.alive = alive
            self.channels = channels
        }
    }

    public struct OutputFacts: Equatable, Sendable {
        public var id: UInt32
        public var uid: String
        public var alive: Bool

        public init(id: UInt32, uid: String, alive: Bool) {
            self.id = id
            self.uid = uid
            self.alive = alive
        }
    }

    public struct InputFacts: Equatable, Sendable {
        public var id: UInt32
        public var uid: String

        public init(id: UInt32, uid: String) {
            self.id = id
            self.uid = uid
        }
    }

    public static func builtinConversation(
        rawBuiltin: RawDeviceFacts?,
        rawOutput: RawDeviceFacts?,
        rawInput: RawDeviceFacts?
    ) -> String {
        let b = rawBuiltin.map {
            BuiltinFacts(id: $0.id, uid: $0.uid, rate: $0.rate, alive: $0.alive, channels: $0.inputChannels)
        }
        let o = rawOutput.map {
            OutputFacts(id: $0.id, uid: $0.uid, alive: $0.alive)
        }
        let i = rawInput.map {
            InputFacts(id: $0.id, uid: $0.uid)
        }
        return builtinConversation(builtin: b, output: o, input: i)
    }

    public static func builtinConversation(
        builtin: BuiltinFacts?,
        output: OutputFacts?,
        input: InputFacts?
    ) -> String {
        // Each component is canonical JSON. UIDs can contain spaces, colons or separators;
        // escaping them prevents one device's UID from impersonating another component.
        func component(_ facts: [Any]?) -> String {
            guard let facts else { return "null" }
            let data = try! JSONSerialization.data(withJSONObject: facts, options: [.fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        }
        let b = component(builtin.map { [$0.id, $0.uid, String($0.rate), $0.alive, $0.channels] })
        let o = component(output.map { [$0.id, $0.uid, $0.alive] })
        let i = component(input.map { [$0.id, $0.uid] })
        return [b, o, i].joined(separator: "\n")
    }

    public static func shortHash(_ fingerprint: String) -> String {
        let digest = Array(Insecure.SHA1.hash(data: Data(fingerprint.utf8)))
        guard digest.count >= 4 else { return "00000000" }
        return String(format: "%02x%02x%02x%02x", digest[0], digest[1], digest[2], digest[3])
    }

    public static func changedField(from before: String?, to after: String) -> String {
        guard let before, before != after else { return "none" }
        let bParts = before.components(separatedBy: "\n")
        let aParts = after.components(separatedBy: "\n")
        guard bParts.count == 3, aParts.count == 3 else { return "builtin" }
        if bParts[0] != aParts[0] { return "builtin" }
        if bParts[1] != aParts[1] { return "output_id" }
        if bParts[2] != aParts[2] { return "input_id" }
        return "none"
    }

    public static func routeFpNote(generation: UInt64, before: String?, after: String) -> String {
        let beforeHash = before.map(shortHash) ?? shortHash(after)
        let afterHash = shortHash(after)
        let changed = changedField(from: before, to: after)
        return "route_fp gen=\(generation) before=\(beforeHash) after=\(afterHash) changed=\(changed)"
    }
}

/// 1.29.6 (D4): exact diagnostic lines for built-in conversation capture.
public enum BuiltinConversationDiagnostics {
    public static func convCaptureNote(
        backend: String = "auhal",
        device: UInt32?,
        sampleRate: Double,
        channels: Int
    ) -> String {
        let dev = device.map(String.init) ?? "0"
        return "conv_capture backend=\(backend) device=\(dev) hw_rate=\(Int(sampleRate.rounded())) hw_ch=\(channels) session_kind=conversation"
    }

    public static func builtinBindNote(result: String, from: UInt32?, to: UInt32?) -> String {
        let fromStr = from.map(String.init) ?? "unverified"
        let toStr = to.map(String.init) ?? "0"
        return "builtin_bind result=\(result) from=\(fromStr) to=\(toStr)"
    }

    public static func convApplyNote(generation: UInt64) -> String {
        "conv_apply=rebuild reason=builtin_auhal gen=\(generation)"
    }
}
