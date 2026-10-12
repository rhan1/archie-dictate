import AudioToolbox
import AVFoundation
import CoreAudio
import DictateCore
import Synchronization

/// v1.8 (L1): the bridge's built-in microphone as a raw AUHAL (Apple TN2091): HAL output unit,
/// input element 1 enabled, output element 0 disabled, `CurrentDevice` = the physical built-in
/// resolved at start. No AVAudioEngine, so no default-device tracking and no aggregate: on
/// 10-12 21:33 the AVAudioEngine child was moved from device 81 to the headset aggregate 154
/// mid-dictation. Ownership is still not an OS guarantee, so the device is read back on every
/// health tick and the device's liveness is observed.
///
/// The IO callback only renders into preallocated slots (no allocation, no locks); a worker
/// drains them every 10 ms, converts to 24 kHz mono Float and hands them to `onFrames`.
final class BuiltinCaptureUnit: BuiltinCapture {
    var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
    var onDeviceLost: ((CaptureEpoch) -> Void)?
    let backend = "auhal"

    private let lock = NSLock()
    /// Held across every call on the opaque unit from another thread (read-back) and across its
    /// teardown, so a read-back can never run on a disposed instance (review #1).
    private let unitLock = NSLock()
    private let worker = DispatchQueue(label: "dictate.builtin.worker")
    private var unit: AudioUnit?
    private var context: BuiltinRenderContext?
    private var teardown = OwnedUnitTeardown()
    private var timer: DispatchSourceTimer?
    private var epoch: CaptureEpoch?
    private var device: AudioDeviceID?
    private var converter: AVAudioConverter?
    private var hardwareFormat: AVAudioFormat?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var lastArrival: TimeInterval?
    private var retained: [BuiltinRenderContext] = []
    private(set) var deviceUID: String?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate,
                                             channels: 1, interleaved: false)!
    /// Notes for the recorder's timeline (start step errors, teardown errors, render errors).
    var note: (String) -> Void = { AppController.note($0) }

    var expectedDeviceID: UInt32? { lock.withLock { device } }
    var lastBufferTime: TimeInterval? { lock.withLock { lastArrival } }
    var isDelivering: Bool {
        lock.withLock { lastArrival.map { ProcessInfo.processInfo.systemUptime - $0 <= CaptureHealth.staleAfter } ?? false }
    }
    var currentDeviceID: UInt32? {
        unitLock.withLock {
            guard let unit = lock.withLock({ self.unit }) else { return nil }
            return try? AudioDevices.currentDevice(of: unit)
        }
    }

    struct StartError: Error, CustomStringConvertible, LocalizedError {
        let step: String
        let status: OSStatus
        var description: String { "builtin_auhal_\(step)=\(status)" }
        var errorDescription: String? { description }
    }

    func start(epoch token: CaptureEpoch) throws {
        stop()
        let id = try AudioDevices.builtInInput()
        let uid = AudioDevices.uid(of: id)
        lock.withLock { epoch = token; device = id; deviceUID = uid; lastArrival = nil }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw StartError(step: "find", status: -1)
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "new")
        guard let unit = created else { throw StartError(step: "new", status: -1) }
        unitLock.withLock { lock.withLock { self.unit = unit; teardown = OwnedUnitTeardown(); teardown.didCreate() } }
        do {
            var on: UInt32 = 1, off: UInt32 = 0
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "enable_input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "disable_output")
            var selected = id
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &selected, UInt32(MemoryLayout<AudioDeviceID>.size)), "current_device")
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "hw_format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
                throw StartError(step: "hw_format_invalid", status: Int32(hardware.mSampleRate))
            }
            // AUHAL's input element does no rate conversion: the client keeps the hardware rate (TN2091).
            var client = AudioStreamBasicDescription(mSampleRate: hardware.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: hardware.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "client_format")
            let context = BuiltinRenderContext(unit: unit, channels: Int(hardware.mChannelsPerFrame))
            var callback = AURenderCallbackStruct(inputProc: builtinInputCallback,
                                                  inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input_callback")
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                           channels: 1, interleaved: false) else {
                throw StartError(step: "mono_format", status: -1)
            }
            lock.withLock {
                self.context = context
                hardwareFormat = mono
                converter = AVAudioConverter(from: mono, to: targetFormat)
            }
            try check(AudioUnitInitialize(unit), "initialize")
            try check(AudioOutputUnitStart(unit), "start")
        } catch {
            stop()
            throw error
        }
        listen(device: id, epoch: token)
        startWorker()
    }

    func stop(epoch token: CaptureEpoch) {
        guard lock.withLock({ epoch === token }) else { return }
        stop()
    }

    /// Idempotent: stop → uninitialize → dispose, each attempted (OwnedUnitTeardown).
    func stop() {
        unitLock.lock()
        defer { unitLock.unlock() }
        let (unit, timer, listeners) = lock.withLock { () -> (AudioUnit?, DispatchSourceTimer?, [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]) in
            epoch = nil
            let taken = (self.unit, self.timer, self.listeners)
            self.timer = nil
            self.listeners = []
            return taken
        }
        timer?.cancel()
        for (object, address, block) in listeners {
            var address = address
            _ = AudioObjectRemovePropertyListenerBlock(object, &address, worker, block)
        }
        if let unit {
            var state = lock.withLock { teardown }
            let errors = state.run(stop: { try self.check(AudioOutputUnitStop(unit), "stop") },
                                   uninitialize: { try self.check(AudioUnitUninitialize(unit), "uninitialize") },
                                   dispose: { try self.check(AudioComponentInstanceDispose(unit), "dispose") })
            lock.withLock {
                teardown = state
                // A unit that may still call back keeps its render context alive.
                if !errors.isEmpty, let context { retained.append(context) }
            }
            for error in errors { note("builtin_teardown_error=\(error)") }
        }
        // The callback can no longer run once the unit is disposed; the worker drains nothing more.
        worker.sync {}
        lock.withLock {
            self.unit = nil
            context = nil
            converter = nil
            hardwareFormat = nil
        }
    }

    private func startWorker() {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + 0.01, repeating: 0.01)
        timer.setEventHandler { [weak self] in self?.drain() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    /// Worker: slots → mono hardware-rate buffer → 24 kHz → onFrames.
    private func drain() {
        guard let (context, converter, format, token) = lock.withLock({ () -> (BuiltinRenderContext, AVAudioConverter, AVAudioFormat, CaptureEpoch)? in
            guard let context, let converter, let hardwareFormat, let epoch else { return nil }
            return (context, converter, hardwareFormat, epoch)
        }) else { return }
        let errors = context.renderErrors.exchange(0, ordering: .relaxed)
        if errors > 0 { note("builtin_render_errors=\(errors) status=\(context.lastStatus.load(ordering: .relaxed))") }
        while let (frames, hostTime) = context.nextSlot({ pointer, count in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return nil as AVAudioPCMBuffer? }
            channel.update(from: pointer, count: count)
            buffer.frameLength = AVAudioFrameCount(count)
            return buffer
        }) {
            guard let input = frames else { continue }
            let ratio = targetFormat.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { continue }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let error { note("builtin_convert_error=\(error.domain):\(error.code)"); continue }
            guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { continue }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            let arrival = ProcessInfo.processInfo.systemUptime
            let start = hostTime != 0 ? AVAudioTime.seconds(forHostTime: hostTime)
                                      : arrival - Double(input.frameLength) / format.sampleRate
            let deliver: (([Float], TimeInterval, CaptureEpoch) -> Void)? = lock.withLock {
                guard epoch === token else { return nil }
                lastArrival = arrival
                return onFrames
            }
            deliver?(chunk, start, token)
        }
    }

    /// Device gone or no longer alive → `onDeviceLost`.
    private func listen(device id: AudioDeviceID, epoch token: CaptureEpoch) {
        let lost: () -> Void = { [weak self] in
            guard let self, self.lock.withLock({ self.epoch === token }) else { return }
            if !AudioDevices.isAlive(id) { self.onDeviceLost?(token) }
        }
        var alive = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let aliveBlock: AudioObjectPropertyListenerBlock = { _, _ in lost() }
        let devicesBlock: AudioObjectPropertyListenerBlock = { _, _ in lost() }
        var installed: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        if AudioObjectAddPropertyListenerBlock(id, &alive, worker, aliveBlock) == noErr {
            installed.append((id, alive, aliveBlock))
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, worker, devicesBlock) == noErr {
            installed.append((AudioObjectID(kAudioObjectSystemObject), devices, devicesBlock))
        }
        lock.withLock { listeners = installed }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw StartError(step: step, status: status) }
    }
}

/// Everything the real-time callback touches, allocated once at start.
final class BuiltinRenderContext: @unchecked Sendable {
    static let slots = 64
    static let maxFrames = 4_096
    let unit: AudioUnit
    let channels: Int
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let channelData: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let slotFrames: UnsafeMutablePointer<Float>
    private let slotCounts: UnsafeMutablePointer<Int>
    private let slotHostTimes: UnsafeMutablePointer<UInt64>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    let renderErrors = Atomic<Int>(0)
    let lastStatus = Atomic<Int32>(0)

    init(unit: AudioUnit, channels: Int) {
        self.unit = unit
        self.channels = max(1, channels)
        bufferList = AudioBufferList.allocate(maximumBuffers: self.channels)
        channelData = .allocate(capacity: self.channels)
        for index in 0..<self.channels {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
            data.initialize(repeating: 0, count: Self.maxFrames)
            channelData[index] = data
            bufferList[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFrames * 4), mData: data)
        }
        slotFrames = .allocate(capacity: Self.slots * Self.maxFrames)
        slotFrames.initialize(repeating: 0, count: Self.slots * Self.maxFrames)
        slotCounts = .allocate(capacity: Self.slots)
        slotCounts.initialize(repeating: 0, count: Self.slots)
        slotHostTimes = .allocate(capacity: Self.slots)
        slotHostTimes.initialize(repeating: 0, count: Self.slots)
    }

    deinit {
        for index in 0..<channels { channelData[index].deallocate() }
        channelData.deallocate()
        free(bufferList.unsafeMutablePointer)
        slotFrames.deallocate()
        slotCounts.deallocate()
        slotHostTimes.deallocate()
    }

    /// Real-time thread: render, mix to mono into the next free slot. No allocation, no locks.
    func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        let count = Int(frames)
        guard count > 0, count <= Self.maxFrames else { dropped.wrappingAdd(1, ordering: .relaxed); return noErr }
        for index in 0..<channels {
            bufferList[index].mDataByteSize = UInt32(count * 4)
            bufferList[index].mData = UnsafeMutableRawPointer(channelData[index])
        }
        let status = AudioUnitRender(unit, flags, time, bus, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else {
            renderErrors.wrappingAdd(1, ordering: .relaxed)
            lastStatus.store(status, ordering: .relaxed)
            return status
        }
        let w = written.load(ordering: .relaxed)
        guard w - read.load(ordering: .acquiring) < Self.slots else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return noErr
        }
        let slot = w % Self.slots
        let destination = slotFrames + slot * Self.maxFrames
        if channels == 1 {
            destination.update(from: channelData[0], count: count)
        } else {
            let scale = 1 / Float(channels)
            for frame in 0..<count {
                var sum: Float = 0
                for index in 0..<channels { sum += channelData[index][frame] }
                destination[frame] = sum * scale
            }
        }
        slotCounts[slot] = count
        let valid = time.pointee.mFlags.contains(.hostTimeValid)
        slotHostTimes[slot] = valid ? time.pointee.mHostTime : 0
        written.store(w + 1, ordering: .releasing)
        return noErr
    }

    /// Worker: the oldest filled slot, copied out by `copy`; nil when empty.
    func nextSlot<T>(_ copy: (UnsafePointer<Float>, Int) -> T?) -> (T?, UInt64)? {
        let r = read.load(ordering: .relaxed)
        guard r < written.load(ordering: .acquiring) else { return nil }
        let slot = r % Self.slots
        let result = copy(UnsafePointer(slotFrames + slot * Self.maxFrames), slotCounts[slot])
        let host = slotHostTimes[slot]
        read.store(r + 1, ordering: .releasing)
        return (result, host)
    }
}

private let builtinInputCallback: AURenderCallback = { refCon, flags, time, bus, frames, _ in
    Unmanaged<BuiltinRenderContext>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
}
