import CoreAudio
import DictateCore

/// The default output device's MUTE FLAG via CoreAudio. Mute only: this file
/// must never reference a volume-level selector (grep-checked in the report).
public final class SystemOutputMute: OutputMuteDevice {
    public init() {}
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public func defaultOutputUID() -> String? {
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

    public func isMuted(uid: String) -> Bool? {
        guard let device = device(for: uid) else { return nil }
        var flags: [Bool] = []
        for element in muteElements(device) {
            var addr = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput, element: element)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
            flags.append(value != 0)
        }
        // Mixed channel flags cannot prove the requested prior was restored.
        guard let first = flags.first, flags.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    public func setMuted(_ muted: Bool, uid: String) -> Bool {
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

    /// v1.12.1 (L6): read-only — the profile whose mute flag the output exposes now (`hfp`/`a2dp`).
    public func outputProfile(uid: String) -> String? {
        guard let device = device(for: uid) else { return nil }
        var rateAddr = Self.address(kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var transportAddr = Self.address(kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        var transport = UInt32(0)
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &rateAddr, 0, nil, &rateSize, &rate) == noErr,
              AudioObjectGetPropertyData(device, &transportAddr, 0, nil, &transportSize, &transport) == noErr else { return nil }
        let profile = BluetoothProfile.profile(transport: transport, rate: rate)
        return profile == "none" ? nil : profile
    }

    /// Watch the muted UID even when it is no longer the default output.
    /// Rebind its rate listener when CoreAudio replaces its object on reconnect.
    public func observeChanges(uid: String, _ action: @escaping () -> Void) -> CaptureCancellation? {
        ChangeWatch(owner: self, uid: uid) { _ in action() }
    }

    /// v1.9 (L2): the same watch while a dictation holds the mute, telling which property changed.
    public func observeOutputChanges(uid: String, _ action: @escaping (OutputChange) -> Void) -> CaptureCancellation? {
        ChangeWatch(owner: self, uid: uid, action: action)
    }

    private final class PropertyListener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        var installed = false
        init(object: AudioObjectID, selector: AudioObjectPropertySelector, action: @escaping () -> Void) {
            self.object = object
            address = SystemOutputMute.address(selector, scope: kAudioObjectPropertyScopeGlobal)
            block = { _, _ in action() }
            installed = AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr
        }
        func cancel() {
            if installed {
                AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
                installed = false
            }
        }
        deinit { cancel() }
    }

    private final class ChangeWatch: CaptureCancellation {
        weak var owner: SystemOutputMute?
        let uid: String
        let action: (OutputChange) -> Void
        var cancelled = false
        var systemListeners: [PropertyListener] = []
        var rateListener: PropertyListener?
        var watchedDevice: AudioDeviceID?
        init(owner: SystemOutputMute, uid: String, action: @escaping (OutputChange) -> Void) {
            self.owner = owner; self.uid = uid; self.action = action
            let system: [(AudioObjectPropertySelector, OutputChange)] = [
                (kAudioHardwarePropertyDefaultOutputDevice, .defaultChanged), (kAudioHardwarePropertyDevices, .devicesChanged)
            ]
            for (selector, reason) in system {
                systemListeners.append(PropertyListener(object: AudioObjectID(kAudioObjectSystemObject), selector: selector) { [weak self] in
                    self?.changed(reason)
                })
            }
            rebind()
        }
        func rebind() {
            let device = owner?.device(for: uid)
            guard device != watchedDevice else { return }
            rateListener?.cancel(); rateListener = nil; watchedDevice = device
            if let device {
                rateListener = PropertyListener(object: device, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
                    self?.changed(.rateChanged)
                }
            }
        }
        func changed(_ reason: OutputChange) {
            guard !cancelled else { return }
            rebind()
            action(reason)
        }
        func cancel() {
            cancelled = true
            systemListeners.forEach { $0.cancel() }; systemListeners = []
            rateListener?.cancel(); rateListener = nil
        }
        deinit { cancel() }
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
