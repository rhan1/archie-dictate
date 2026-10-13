import AVFoundation
import CoreAudio
import DictateCore

/// v1.12: the read-only device questions `AudioRecorder` asks at start (default input kind, the
/// headset's device and UID, its name). Production reads CoreAudio; recorder tests inject a fake
/// route so no device is ever queried.
struct CaptureRouteProbe {
    var eligibility: () -> (CaptureBridge.DefaultInput, Bool)?
    var defaultInput: () -> AudioDeviceID?
    var uid: (AudioDeviceID) -> String?
    var defaultInputName: () -> String?
    /// The headset restart's idle check (`kAudioDevicePropertyDeviceIsRunningSomewhere`).
    var isRunningSomewhere: (AudioDeviceID) -> Bool? = { _ in nil }

    static let system = CaptureRouteProbe(
        eligibility: { try? AudioDevices.bridgeEligibility() },
        defaultInput: { AudioDevices.defaultInputDevice() },
        uid: { AudioDevices.uid(of: $0) },
        defaultInputName: { AVCaptureDevice.default(for: .audio)?.localizedName },
        isRunningSomewhere: { AudioDevices.isRunningSomewhere($0) })
}
