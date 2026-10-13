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
    /// v1.13 (L2): the Bluetooth headset is already on HFP (read-only rate/transport of the default output).
    var hfpAlready: () -> Bool = { false }

    static let system = CaptureRouteProbe(
        eligibility: { try? AudioDevices.bridgeEligibility() },
        defaultInput: { AudioDevices.defaultInputDevice() },
        uid: { AudioDevices.uid(of: $0) },
        defaultInputName: { AVCaptureDevice.default(for: .audio)?.localizedName },
        isRunningSomewhere: { AudioDevices.isRunningSomewhere($0) },
        hfpAlready: { BluetoothProfile.sample() == "hfp" })
}
