import Foundation
import AVFoundation

/// One capture-unit factory boundary. The engine arm supplies an input-node
/// VPIO implementation and its existing HAL implementation. Tests supply
/// units that never instantiate AVAudioEngine or touch devices.
struct CaptureInputUnit {
    var start: () throws -> Void
    var dispose: () -> Void
    var configure: (AVAudioVoiceProcessingOtherAudioDuckingConfiguration) throws -> Void = { _ in }
}

enum CaptureVoiceProcessing {
    enum Unit: String { case halout, vpio }
    enum State: String { case off, on, unavailable }
    struct Refusal: Error { let reason: String }

    /// A refusal discards the entire possibly-mutated VPIO graph before a
    /// fresh legacy graph is started. There is no toggle-back on a poisoned
    /// unit, and errors starting the fallback still propagate to the host.
    static func start(requested: Bool, builtin: Bool, bluetooth: Bool?,
                      make: (Unit) throws -> CaptureInputUnit,
                      note: (String) -> Void) throws -> State {
        guard requested else { try make(.halout).start(); return .off }
        let reason: String?
        if bluetooth == true { reason = "bluetooth_route" }
        else if bluetooth == nil { reason = "route_unknown" }
        else if !builtin { reason = "unsupported_route" }
        else { reason = nil }
        if let reason {
            note("voice_processing=unavailable reason=\(reason)")
            try make(.halout).start()
            return .unavailable
        }
        var processed: CaptureInputUnit?
        do {
            let unit = try make(.vpio)
            processed = unit
            try unit.configure(AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min))
            try unit.start()
            note("voice_processing=on")
            return .on
        } catch {
            processed?.dispose()
            let reason = (error as? Refusal)?.reason ?? "unit_failed"
            note("voice_processing=unavailable reason=\(reason)")
            try make(.halout).start()
            return .unavailable
        }
    }
}
