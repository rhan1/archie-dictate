import AVFoundation
import CoreAudio

/// 1.29: how a Bluetooth conversation applies an admitted route generation on the AVAudioEngine arm.
///
/// When the input the engine was activated on is still the default input (same device ID and full UID) and
/// still the engine's own bound device, the apply restarts the SAME engine in place (remove the tap, install the
/// converting tap, start). Tearing the engine down instead drops the headset's voice link (eSCO) and starts the
/// replacement inside the unfinished HFP transition, which self-stops it and opens the next generation — the
/// ⌘⌘ loop of 2026-11-05. Anything else (not Bluetooth, an unknown read, a different device, an engine bound
/// elsewhere, the cap) rebuilds exactly as before.
///
/// `inPlaceCap` is a local fallback policy: after three consecutive successful in-place applies the next apply
/// rebuilds and the count starts again. It is NOT a bound on generations (`IIIRIIIR…` is a valid trace).
/// Pure values only: no lock, no CoreAudio call.
enum ConversationRouteReplacement {
    struct Bound: Equatable, Sendable {
        let device: AudioDeviceID
        let uid: String
    }

    static let inPlaceCap = 3

    enum Decision: Equatable, Sendable {
        case inPlace
        case rebuild(reason: String)
    }

    /// `observed` = the default input and its UID sampled once for this apply (nil: either read failed);
    /// `engineDevice` = the engine input unit's own bound device (nil: no unit / unreadable).
    static func decide(bluetooth: Bool, bound: Bound?, observed: Bound?, engineDevice: AudioDeviceID?,
                       consecutive: Int) -> Decision {
        guard bluetooth else { return .rebuild(reason: "not_bluetooth") }
        guard let bound else { return .rebuild(reason: "no_bound") }
        guard let observed, observed.device != 0, !observed.uid.isEmpty else { return .rebuild(reason: "unknown_read") }
        guard let engineDevice, engineDevice != 0 else { return .rebuild(reason: "engine_unreadable") }
        guard observed == bound else { return .rebuild(reason: "device_changed") }
        guard engineDevice == bound.device else { return .rebuild(reason: "engine_bound_elsewhere") }
        guard consecutive < inPlaceCap else { return .rebuild(reason: "cap") }
        return .inPlace
    }

    /// The identity an eligible activation may record: the sampled default (ID + UID) only when the engine's own
    /// read-back names the same device. Any uncertainty or disagreement records nothing (the next apply rebuilds).
    static func binding(observed: Bound?, engineDevice: AudioDeviceID?) -> Bound? {
        guard let observed, observed.device != 0, !observed.uid.isEmpty,
              let engineDevice, engineDevice == observed.device else { return nil }
        return observed
    }

    /// One line per engine-arm apply, written when its outcome is known:
    /// `conv_apply=<in_place|rebuild> reason=<…> bound=<id>/"<uid>"|nil consecutive=<n> gen=<g> …`.
    /// `consecutive` counts this apply (in place: 1…3; rebuild: 0). UIDs are quoted (they contain `:`) and never parsed back.
    static func note(inPlace: Bool, reason: String, bound: Bound?, observed: Bound?, engineDevice: AudioDeviceID?,
                     engineRunning: Bool?, consecutive: Int, generation: UInt64) -> String {
        func show(_ b: Bound?) -> String { b.map { "\($0.device)/\"\($0.uid)\"" } ?? "nil" }
        return "conv_apply=\(inPlace ? "in_place" : "rebuild") reason=\(reason) bound=\(show(bound)) consecutive=\(consecutive)"
            + " gen=\(generation) obs=\(show(observed)) engine_dev=\(engineDevice.map(String.init) ?? "nil")"
            + " engine_running=\(engineRunning.map { $0 ? "1" : "0" } ?? "nil")"
    }
}

/// 1.29: the engine arm's native input-node operations. Production wraps this recorder's `AVAudioEngine`
/// (exactly the calls the recorder made before); hardware-free tests supply a fake node so the recorder's own
/// apply policy, tap tokens, conversion and fallback run without any audio device.
struct EngineInputNative {
    /// The input node's bus-0 input (hardware) and output formats.
    var formats: () throws -> (hardware: AVAudioFormat, output: AVAudioFormat)
    /// Installs the bus-0 tap. `nil` = the node's own current output format (the bus is left as it is); an explicit
    /// format asks the node to set its bus-0 output format to it (AVAudioNode.h) — 1.29.2 passes the hardware format
    /// only when a conversation's in-place apply finds the stopped node's output bus stale.
    var installTap: (AVAudioFormat?, @escaping AVAudioNodeTapBlock) throws -> Void
    var removeTap: () throws -> Void
    var prepare: () throws -> Void
    var start: () throws -> Void
    /// The device the input unit is bound to (nil: no unit, or unreadable).
    var boundDevice: () -> AudioDeviceID?
    /// Nil: unreadable.
    var isRunning: () -> Bool?
    /// The capture device name for `stats.device`.
    var deviceName: () -> String?
}

/// 1.29 test seam (nil in production): the conversation engine arm on a fake engine. `native` is the current fake
/// engine's node; `rebuild` replaces the fake engine (production: `rebuild()`); `make` is the start-unit factory the
/// voice-processing policy runs after a rebuild (production: `makeCaptureInputUnit`).
struct OfflineConversationEngine {
    var native: () -> EngineInputNative
    var rebuild: () throws -> Void
    var make: (CaptureVoiceProcessing.Unit) throws -> CaptureInputUnit
}
