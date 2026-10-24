import AVFoundation
import AppKit
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

    /// Nil is an unreadable route; conservatively decline VPIO.
    var outputIsBluetooth: () -> Bool? = { false }

    /// BT1 (v1.19): watches the system default input for one Bluetooth dictation. The handler gets the
    /// new default (nil: unreadable) on a private queue; releasing the returned token removes the
    /// watch. Read-only (a property listener; no device is opened). Nil: nothing is watched.
    var watchDefaultInput: (@escaping (AudioDeviceID?) -> Void) -> AnyObject? = { _ in nil }

    var effectiveRoute: () -> String = { "fixture" }
    var watchConversationRoute: (@escaping () -> Void) -> AnyObject? = { _ in nil }

    static let system = CaptureRouteProbe(
        eligibility: { try? AudioDevices.bridgeEligibility() },
        defaultInput: { AudioDevices.defaultInputDevice() },
        uid: { AudioDevices.uid(of: $0) },
        defaultInputName: { AVCaptureDevice.default(for: .audio)?.localizedName },
        isRunningSomewhere: { AudioDevices.isRunningSomewhere($0) },
        hfpAlready: { BluetoothProfile.sample() == "hfp" },
        outputIsBluetooth: { AudioDevices.outputIsBluetooth() },
        watchDefaultInput: { DefaultInputWatch($0) },
        effectiveRoute: { ConversationRouteWatch.fingerprint() },
        watchConversationRoute: { ConversationRouteWatch($0) })
}

/// BT1: a `kAudioHardwarePropertyDefaultInputDevice` listener on the system object for one dictation;
/// the handler receives the default as read back after the change. Removed when released.
final class DefaultInputWatch {
    private let queue = DispatchQueue(label: "dictate.capture.default-input")
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let block: AudioObjectPropertyListenerBlock
    private var added = false

    init?(_ handler: @escaping (AudioDeviceID?) -> Void) {
        block = { _, _ in handler(AudioDevices.defaultInputDevice()) }
        added = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr
        if !added { return nil }
    }

    deinit {
        if added { _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) }
    }
}

/// Read-only conversation route observation. A single fingerprint normalizes notification bursts.
/// Device listeners are rebound with the defaults; destroying the token removes every observer.
final class ConversationRouteWatch {
    private let queue = DispatchQueue(label: "dictate.capture.conversation-route")
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var powerObservers: [NSObjectProtocol] = []
    private let changed: () -> Void

    init(_ changed: @escaping () -> Void) {
        self.changed = changed
        rebind()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            powerObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] _ in self?.queue.async { [weak self] in self?.changed() }
            })
        }
    }

    private func rebind() {
        removeListeners()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] { add(system, selector) }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            guard let device: AudioDeviceID = Self.read(system, selector) else { continue }
            add(device, kAudioDevicePropertyDeviceIsAlive)
            add(device, kAudioDevicePropertyNominalSampleRate)
            add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
            add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        }
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.rebind()
            self.changed()
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func removeListeners() {
        for (object, var address, block) in listeners {
            _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listeners.removeAll()
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size == MemoryLayout<T>.size else { return nil }
        let value = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.load(as: T.self)
    }

    static func fingerprint() -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map { selector in
            guard let device: AudioDeviceID = read(system, selector) else { return "unknown" }
            let rate: Double? = read(device, kAudioDevicePropertyNominalSampleRate)
            let alive: UInt32? = read(device, kAudioDevicePropertyDeviceIsAlive)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: selector == kAudioHardwarePropertyDefaultInputDevice ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            var channels: UInt32 = 0
            if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 {
                let bytes = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
                defer { bytes.deallocate() }
                if AudioObjectGetPropertyData(device, &address, 0, nil, &size, bytes) == noErr {
                    let list = UnsafeMutableAudioBufferListPointer(bytes.assumingMemoryBound(to: AudioBufferList.self))
                    channels = list.reduce(0) { $0 + $1.mNumberChannels }
                }
            }
            return "\(device):\(AudioDevices.uid(of: device) ?? "unknown"):\(rate ?? 0):\(alive ?? 0):\(channels)"
        }.joined(separator: "|")
    }

    deinit {
        removeListeners()
        for observer in powerObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
