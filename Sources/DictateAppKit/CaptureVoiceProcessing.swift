import Foundation
import AVFoundation
import DictateCore

/// One capture-unit factory boundary. The engine arm supplies an input-node
/// VPIO implementation and its existing HAL implementation. Tests supply
/// units that never instantiate AVAudioEngine or touch devices.
struct CaptureInputUnit {
    var start: () throws -> Void
    var dispose: () -> Void
    var configure: (AVAudioVoiceProcessingOtherAudioDuckingConfiguration) throws -> Void = { _ in }
    /// Read AFTER configure: enabling VP can replace mono hardware with an aggregate input.
    var hardwareChannels: () throws -> AVAudioChannelCount = { 1 }
}

enum CaptureVoiceProcessing {
    enum Unit: String { case halout, vpio }
    enum State: String { case off, on, unavailable, fallback }
    struct Refusal: Error { let reason: String }

    /// A refusal discards the entire possibly-mutated VPIO graph before a
    /// fresh legacy graph is started. There is no toggle-back on a poisoned
    /// unit, and errors starting the fallback still propagate to the host.
    static func start(requested: Bool, builtin: Bool, bluetooth: Bool?,
                      fallbackEnabled: Bool = true,
                      make: (Unit) throws -> CaptureInputUnit,
                      note: (String) -> Void, stateChanged: (State) -> Void = { _ in }) throws -> State {
        guard requested else { stateChanged(.off); try make(.halout).start(); return .off }
        let reason: String?
        if bluetooth == true { reason = "bluetooth_route" }
        else if bluetooth == nil { reason = "route_unknown" }
        else if !builtin { reason = "unsupported_route" }
        else { reason = nil }
        if let reason {
            stateChanged(.unavailable)
            note("voice_processing=unavailable reason=\(reason)")
            try make(.halout).start()
            return .unavailable
        }
        var processed: CaptureInputUnit?
        do {
            let unit = try make(.vpio)
            processed = unit
            try unit.configure(AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min))
            if fallbackEnabled, try unit.hardwareChannels() > 2 {
                throw Refusal(reason: "multichannel_input")
            }
            try unit.start()
            stateChanged(.on)
            note("voice_processing=on")
            return .on
        } catch {
            processed?.dispose()
            let reason = (error as? Refusal)?.reason ?? "unit_failed"
            if reason == "multichannel_input" {
                return try startFallback(reason: reason, make: make, note: note, stateChanged: stateChanged)
            }
            stateChanged(.unavailable)
            note("voice_processing=unavailable reason=\(reason)")
            try make(.halout).start()
            return .unavailable
        }
    }

    /// The health clock owns this retry, before it can emit mic_dead. A real tap callback
    /// (including quiet PCM) disarms it; stale/zero audio after a callback keeps normal health policy.
    static func firstBufferExpired(state: State, receivedBuffer: Bool,
                                   health: CaptureHealth, at now: TimeInterval) -> Bool {
        guard state == .on, !receivedBuffer, let boundary = health.boundary else { return false }
        return now >= boundary + CaptureHealth.failAfter
    }

    static func startFallback(reason: String, make: (Unit) throws -> CaptureInputUnit,
                              note: (String) -> Void, stateChanged: (State) -> Void = { _ in }) throws -> State {
        stateChanged(.fallback)
        note("voice_processing=fallback reason=\(reason)")
        try make(.halout).start()
        return .fallback
    }
}
