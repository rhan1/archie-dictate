import AudioToolbox
import CoreAudio
import DictateCore
import Foundation

/// v1.12 (L3): stream format descriptor for HAL input devices.
struct HALStreamFormat: Equatable, Sendable {
    var sampleRate: Double
    var channels: Int

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// The callback signature for mono rendered samples from the driver.
typealias HALRenderSink = (UnsafePointer<Float>, Int, UInt64) -> Void

/// v1.12 (L3): an internal protocol abstracting every HAL/AudioUnit call the headset unit makes,
/// so the unit's logic is testable offline with a fake driver.
protocol HALInputDriver: AnyObject {
    /// Resolves the device ID corresponding to `uid`. Throws when no device has that UID.
    func resolveDevice(uid: String) throws -> UInt32
    /// Creates the AUHAL, enables input element 1, disables output element 0, binds CurrentDevice,
    /// and reads the hardware input format.
    func open(device: UInt32) throws -> HALStreamFormat
    /// Sets the client format (hardware rate, float32, non-interleaved) and installs the input callback.
    func configure(clientRate: Double, channels: Int, render: @escaping HALRenderSink) throws
    /// Starts IO on the unit.
    func start() throws
    /// Stop → uninitialize → dispose via OwnedUnitTeardown; returns any errors encountered.
    func stop() -> [Error]
    /// Reads back the current input stream format.
    func currentFormat() -> HALStreamFormat?
    /// Checks whether the device is still alive.
    func isAlive(device: UInt32) -> Bool
    /// Installs device-alive, device-list and nominal sample rate / format listeners.
    func listen(device: UInt32, onChange: @escaping () -> Void) -> AnyObject
    /// Removes listeners associated with the token.
    func unlisten(_ token: AnyObject)
}

extension HALInputDriver {
    func unlisten(_ token: AnyObject) {}
}

/// The production HAL/AudioUnit driver (compiled but never exercised by offline tests).
final class AudioUnitHALDriver: HALInputDriver {
    private var unit: AudioUnit?
    private var deviceID: AudioDeviceID?
    private var teardown = OwnedUnitTeardown()
    private var renderContext: HeadsetHALRenderContext?
    /// Contexts a running unit may still call into: kept alive until the unit is disposed.
    private var retired: [HeadsetHALRenderContext] = []
    private var initialized = false
    private let listenerQueue = DispatchQueue(label: "dictate.headset.hal.listeners")

    func resolveDevice(uid: String) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef = Unmanaged.passUnretained(uid as CFString)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let qualifierSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            qualifierSize,
            &uidRef,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw HeadsetCaptureUnit.StartError(step: "resolve_device", status: status != noErr ? status : -1)
        }
        return deviceID
    }

    func open(device: UInt32) throws -> HALStreamFormat {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HeadsetCaptureUnit.StartError(step: "find", status: -1)
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "new")
        guard let unit = created else {
            throw HeadsetCaptureUnit.StartError(step: "new", status: -1)
        }
        self.unit = unit
        self.deviceID = device
        self.teardown = OwnedUnitTeardown()
        self.teardown.didCreate()

        var on: UInt32 = 1, off: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "enable_input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "disable_output")
        var selected = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &selected, UInt32(MemoryLayout<AudioDeviceID>.size)), "current_device")

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "hw_format")
        return HALStreamFormat(sampleRate: hardware.mSampleRate, channels: Int(hardware.mChannelsPerFrame))
    }

    func configure(clientRate: Double, channels: Int, render: @escaping HALRenderSink) throws {
        guard let unit else { throw HeadsetCaptureUnit.StartError(step: "not_open", status: -1) }
        var client = AudioStreamBasicDescription(
            mSampleRate: clientRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // A format change while running: the AUHAL input element does no rate conversion, so the
        // client format follows the hardware — stop, uninitialize, set, then initialize + start again.
        let restart = initialized
        if restart {
            try check(AudioOutputUnitStop(unit), "reconfigure_stop")
            try check(AudioUnitUninitialize(unit), "reconfigure_uninitialize")
            initialized = false
        }
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size),
                  "client_format")

        let context = HeadsetHALRenderContext(unit: unit, channels: channels, renderSink: render)
        if let old = renderContext { retired.append(old) }
        self.renderContext = context
        var callback = AURenderCallbackStruct(
            inputProc: headsetInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input_callback")
        if restart { try start() }
    }

    func start() throws {
        guard let unit else { throw HeadsetCaptureUnit.StartError(step: "not_open", status: -1) }
        try check(AudioUnitInitialize(unit), "initialize")
        initialized = true
        try check(AudioOutputUnitStart(unit), "start")
    }

    func stop() -> [Error] {
        guard let unit else { return [] }
        var state = teardown
        let errors = state.run(
            stop: { try self.check(AudioOutputUnitStop(unit), "stop") },
            uninitialize: { try self.check(AudioUnitUninitialize(unit), "uninitialize") },
            dispose: { try self.check(AudioComponentInstanceDispose(unit), "dispose") }
        )
        self.teardown = state
        self.unit = nil
        initialized = false
        // A unit whose teardown failed may still call back: keep its contexts alive.
        if errors.isEmpty { renderContext = nil; retired.removeAll() }
        return errors
    }

    func currentFormat() -> HALStreamFormat? {
        guard let unit else { return nil }
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr else {
            return nil
        }
        return HALStreamFormat(sampleRate: hardware.mSampleRate, channels: Int(hardware.mChannelsPerFrame))
    }

    func isAlive(device: UInt32) -> Bool {
        AudioDevices.isAlive(AudioDeviceID(device))
    }

    func listen(device: UInt32, onChange: @escaping () -> Void) -> AnyObject {
        let id = AudioDeviceID(device)
        let addresses = [
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain),
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                       mScope: kAudioObjectPropertyScopeInput,
                                       mElement: kAudioObjectPropertyElementMain),
        ]
        var installed: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }

        for var addr in addresses {
            let target = addr.mSelector == kAudioHardwarePropertyDevices
                ? AudioObjectID(kAudioObjectSystemObject)
                : id
            if AudioObjectAddPropertyListenerBlock(target, &addr, listenerQueue, block) == noErr {
                installed.append((target, addr, block))
            }
        }
        return ListenerToken(listeners: installed, queue: listenerQueue)
    }

    func unlisten(_ token: AnyObject) {
        if let token = token as? ListenerToken {
            token.cancel()
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw HeadsetCaptureUnit.StartError(step: step, status: status) }
    }
}

private final class ListenerToken {
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]
    private let queue: DispatchQueue
    private var isCancelled = false

    init(listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)], queue: DispatchQueue) {
        self.listeners = listeners
        self.queue = queue
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        for (object, address, block) in listeners {
            var addr = address
            _ = AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
        }
        listeners.removeAll()
    }

    deinit {
        cancel()
    }
}

final class HeadsetHALRenderContext: @unchecked Sendable {
    static let maxFrames = 4_096
    let unit: AudioUnit
    let channels: Int
    let renderSink: HALRenderSink
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let channelData: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let monoScratch: UnsafeMutablePointer<Float>

    init(unit: AudioUnit, channels: Int, renderSink: @escaping HALRenderSink) {
        self.unit = unit
        self.channels = max(1, channels)
        self.renderSink = renderSink
        bufferList = AudioBufferList.allocate(maximumBuffers: self.channels)
        channelData = .allocate(capacity: self.channels)
        for index in 0..<self.channels {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            data.initialize(repeating: 0, count: Self.maxFrames)
            channelData[index] = data
            bufferList[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFrames * 4), mData: data)
        }
        monoScratch = .allocate(capacity: Self.maxFrames)
        monoScratch.initialize(repeating: 0, count: Self.maxFrames)
    }

    deinit {
        for index in 0..<channels { channelData[index].deallocate() }
        channelData.deallocate()
        free(bufferList.unsafeMutablePointer)
        monoScratch.deallocate()
    }

    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        let count = Int(frames)
        guard count > 0, count <= Self.maxFrames else { return noErr }
        for index in 0..<channels {
            bufferList[index].mDataByteSize = UInt32(count * 4)
            bufferList[index].mData = UnsafeMutableRawPointer(channelData[index])
        }
        let status = AudioUnitRender(unit, flags, time, bus, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }
        let valid = time.pointee.mFlags.contains(.hostTimeValid)
        let hostTime = valid ? time.pointee.mHostTime : 0
        if channels == 1 {
            renderSink(channelData[0], count, hostTime)
        } else {
            let scale = 1 / Float(channels)
            for frame in 0..<count {
                var sum: Float = 0
                for index in 0..<channels { sum += channelData[index][frame] }
                monoScratch[frame] = sum * scale
            }
            renderSink(monoScratch, count, hostTime)
        }
        return noErr
    }
}

private let headsetInputCallback: AURenderCallback = { refCon, flags, time, bus, frames, _ in
    Unmanaged<HeadsetHALRenderContext>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
}
