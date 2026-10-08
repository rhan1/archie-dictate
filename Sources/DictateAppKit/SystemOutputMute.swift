import CoreAudio
import DictateCore

/// The default output device's MUTE FLAG via CoreAudio. Mute only: this file
/// must never reference a volume-level selector (grep-checked in the report).
final class SystemOutputMute: OutputMuteDevice {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func defaultOutputUID() -> String? {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        var uidAddr = Self.address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    func isMuted(uid: String) -> Bool? {
        guard let device = device(for: uid), let element = muteElements(device).first else { return nil }
        var addr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    func setMuted(_ muted: Bool, uid: String) -> Bool {
        guard let device = device(for: uid) else { return false }
        let elements = muteElements(device)
        guard !elements.isEmpty else { return false }
        var ok = true
        for element in elements {
            var addr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)
            var value: UInt32 = muted ? 1 : 0
            ok = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr && ok
        }
        return ok
    }

    /// The main element's settable mute flag, else per-channel flags 1…2.
    private func muteElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        func settable(_ element: AudioObjectPropertyElement) -> Bool {
            var addr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)
            var isSettable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &addr)
                && AudioObjectIsPropertySettable(device, &addr, &isSettable) == noErr && isSettable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter(settable)
    }

    private func device(for uid: String) -> AudioDeviceID? {
        var addr = Self.address(kAudioHardwarePropertyTranslateUIDToDevice, scope: kAudioObjectPropertyScopeGlobal)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }
}
