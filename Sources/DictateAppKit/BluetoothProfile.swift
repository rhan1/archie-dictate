import CoreAudio

/// Read-only output diagnostics: querying properties never opens an input device.
enum BluetoothProfile {
    static func sample() -> String {
        var device = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device),
              device != kAudioObjectUnknown else { return "none" }
        var rate = Float64(0)
        var transport = UInt32(0)
        guard read(device, kAudioDevicePropertyNominalSampleRate, &rate),
              read(device, kAudioDevicePropertyTransportType, &transport) else { return "none" }
        return profile(transport: transport, rate: rate)
    }

    static func profile(transport: UInt32, rate: Float64) -> String {
        guard transport == kAudioDeviceTransportTypeBluetooth ||
              transport == kAudioDeviceTransportTypeBluetoothLE else { return "none" }
        if rate <= 24_000 { return "hfp" }
        if rate >= 44_100 { return "a2dp" }
        return "none"
    }

    private static func read<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) == noErr
        }
    }
}
