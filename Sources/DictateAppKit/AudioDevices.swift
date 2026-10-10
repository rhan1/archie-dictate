import CoreAudio
import AudioToolbox
import AVFoundation
import DictateCore

/// Hardware lookup is kept out of Core. Selection belongs to a fresh, stopped engine.
enum AudioDevices {
    static func builtInInput() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status)
        for device in devices {
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var type = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &type, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 {
                return device
            }
        }
        throw NSError(domain: "AudioDevices", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "No built-in microphone with input streams"])
    }

    /// Use CoreAudio's actual default input, rather than a display name heuristic.
    static func bridgeEligibility() throws -> (CaptureBridge.DefaultInput, Bool) {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                            0, nil, &size, &device))
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport))
        let input: CaptureBridge.DefaultInput
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: input = .builtin
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: input = .bluetooth
        default: input = .other
        }
        return (input, (try? builtInInput()) != nil)
    }

    static func selectBuiltIn(on input: AVAudioInputNode) throws {
        var device = try builtInInput()
        guard let unit = input.audioUnit else {
            throw NSError(domain: "AudioDevices", code: 2, userInfo: [NSLocalizedDescriptionKey: "Input AUHAL unavailable"])
        }
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)))
    }
    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
