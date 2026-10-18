import AVFoundation
import AudioToolbox
import CoreAudio
import DictateCore
import Foundation
import Synchronization

/// v1.12 (L3): the headset capture client behind `headset_backend=auhal`.
/// Binds explicitly to the headset device UID, captures input element 1 only (no output, no aggregate,
/// no default device tracking), converts from the hardware rate to 24 kHz mono Float, and delivers
/// frames with host-clock start times on a worker queue.
final class HeadsetCaptureUnit: HeadsetCapture {
    static let callbackStall: TimeInterval = 0.5

    var onFrames: (([Float], TimeInterval, CaptureEpoch) -> Void)?
    var onEvent: ((HeadsetCaptureEvent, CaptureEpoch) -> Void)?
    let backend = "auhal"
    var note: (String) -> Void = { AppController.note($0) }
    var makeConverter: (AVAudioFormat, AVAudioFormat) -> AVAudioConverter? = { AVAudioConverter(from: $0, to: $1) }

    private let driver: HALInputDriver
    private let clock: () -> TimeInterval
    private let workerInterval: TimeInterval

    private let lock = NSLock()
    /// Recursive: a failed start tears down (stop) while start still holds it.
    private let unitLock = NSRecursiveLock()
    private let worker: DispatchQueue = {
        let queue = DispatchQueue(label: "dictate.headset.worker")
        queue.setSpecific(key: HeadsetCaptureUnit.workerKey, value: ())
        return queue
    }()
    private static let workerKey = DispatchSpecificKey<Void>()
    private let context = HeadsetRenderContext()
    /// The AUHAL arm's native-call boundary (test seams nil in production).
    let headsetNative = HeadsetNativeBoundary()

    private var _isRunning = false
    private var _lastCallbackTime: TimeInterval?
    private var _formatGeneration = 0
    private var _counters = SourceCounters()

    private var epoch: CaptureEpoch?
    private var deviceUID: String?
    private var deviceID: UInt32?
    private var startTime: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var listenerToken: AnyObject?
    private var hardwareFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// v1.17 (R4): the hardware rate whose conversion chain a caught native exception left unbuilt;
    /// the worker rebuilds it before the next buffer (same unit, no restart).
    private var pendingRebuild: Double?
    /// v1.17 (R4): a format change whose chain build a caught native exception aborted; the worker
    /// retries it at the top of its next drain, before that drain reads the hardware format.
    private var pendingFormatChange: HALStreamFormat?

    private var callbacksStoppedReported = false
    private var deviceLostReported = false
    private var isFormatInvalid = false
    private var formatInvalidReported = false
    private var converterFailedReported = false
    private var hasStartedSession = false
    private var hasDriverSession = false
    /// The session number render callbacks are stamped with (no object retains on the IO thread).
    private var session = 0
    private var seenCallbacks = 0

    var isRunning: Bool { lock.withLock { _isRunning } }
    var lastCallbackTime: TimeInterval? { lock.withLock { _lastCallbackTime } }
    var formatGeneration: Int { lock.withLock { _formatGeneration } }
    var counters: SourceCounters { lock.withLock { _counters } }

    struct StartError: Error, CustomStringConvertible, LocalizedError {
        let step: String
        let status: OSStatus
        init(step: String, status: OSStatus = -1) {
            self.step = step
            self.status = status
        }
        var description: String { "headset_auhal_\(step)=\(status)" }
        var errorDescription: String? { description }
    }

    init(driver: HALInputDriver = AudioUnitHALDriver(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         workerInterval: TimeInterval = 0.01) {
        self.driver = driver
        self.clock = clock
        self.workerInterval = workerInterval
    }

    func start(deviceUID: String, epoch token: CaptureEpoch) throws {
        stop()
        unitLock.lock()
        defer { unitLock.unlock() }

        let now = clock()
        lock.withLock {
            epoch = token
            self.deviceUID = deviceUID
            startTime = now
            _lastCallbackTime = nil
            callbacksStoppedReported = false
            deviceLostReported = false
            isFormatInvalid = false
            formatInvalidReported = false
            converterFailedReported = false
            pendingRebuild = nil
            pendingFormatChange = nil
            _counters = SourceCounters()
            _formatGeneration = 1
            hasDriverSession = true
            session += 1
            context.session.store(session, ordering: .releasing)
            seenCallbacks = context.callbacks.load(ordering: .acquiring)
        }

        do {
            let resolvedID: UInt32
            do {
                resolvedID = try driver.resolveDevice(uid: deviceUID)
            } catch let err as StartError {
                throw err
            } catch {
                throw StartError(step: "resolve_device", status: OSStatus((error as NSError).code))
            }
            lock.withLock { self.deviceID = resolvedID }

            let hwFormat: HALStreamFormat
            do {
                hwFormat = try driver.open(device: resolvedID)
            } catch let err as StartError {
                throw err
            } catch {
                throw StartError(step: "open", status: OSStatus((error as NSError).code))
            }

            guard hwFormat.sampleRate > 0, hwFormat.channels > 0 else {
                throw StartError(step: "hw_format_invalid", status: Int32(hwFormat.sampleRate))
            }

            let sink = makeRenderSink()
            do {
                try driver.configure(clientRate: hwFormat.sampleRate, channels: hwFormat.channels, render: sink)
            } catch let err as StartError {
                throw err
            } catch {
                throw StartError(step: "configure", status: OSStatus((error as NSError).code))
            }

            // A native exception here is not a failed start: the unit runs and the worker rebuilds the
            // chain before the first buffer. A format/converter that is merely unavailable keeps v1.16's path.
            var built: Conversion?
            var faulted = false
            do { built = try conversion(rate: hwFormat.sampleRate) } catch {
                nativeFailed(error)
                faulted = true
            }
            if !faulted, built == nil { throw StartError(step: "mono_format", status: -1) }

            let conv = built?.converter
            var convFailedAtStart = false
            lock.withLock {
                hardwareFormat = built?.mono
                converter = conv
                pendingRebuild = faulted ? hwFormat.sampleRate : nil
                if !faulted, conv == nil {
                    converterFailedReported = true
                    convFailedAtStart = true
                }
            }

            do {
                try driver.start()
            } catch let err as StartError {
                throw err
            } catch {
                throw StartError(step: "start", status: OSStatus((error as NSError).code))
            }

            let listenerToken = driver.listen(device: resolvedID) { [weak self] in
                self?.worker.async {
                    self?.handleDeviceOrFormatChange()
                }
            }
            lock.withLock { self.listenerToken = listenerToken }

            startWorker()

            lock.withLock {
                _isRunning = true
                hasStartedSession = true
            }

            onEvent?(.started(deviceUID: deviceUID, sampleRate: hwFormat.sampleRate, channels: hwFormat.channels), token)
            if convFailedAtStart {
                onEvent?(.converterFailed, token)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop(epoch token: CaptureEpoch) {
        guard lock.withLock({ epoch === token }) else { return }
        stop()
    }

    func stop() {
        unitLock.lock()
        defer { unitLock.unlock() }

        let (wasActive, epochToken, token, timer) = lock.withLock { () -> (Bool, CaptureEpoch?, AnyObject?, DispatchSourceTimer?) in
            guard hasDriverSession || _isRunning || epoch != nil else {
                return (false, nil, nil, nil)
            }
            let active = hasStartedSession
            let ep = epoch
            let tok = listenerToken
            let tm = self.timer
            _isRunning = false
            hasDriverSession = false
            hasStartedSession = false
            epoch = nil
            listenerToken = nil
            self.timer = nil
            return (active, ep, tok, tm)
        }

        guard let epochToken else { return }

        if let token {
            driver.unlisten(token)
        }
        timer?.cancel()
        // Flush the worker BEFORE the driver is disposed: an in-flight drain may still read the
        // unit's format or reconfigure it. Never sync onto the worker from the worker itself (a
        // frame/event callback that tears capture down would deadlock).
        if DispatchQueue.getSpecific(key: Self.workerKey) == nil { worker.sync {} }

        let errors = driver.stop()
        for error in errors {
            note("headset_teardown_error=\(error)")
        }

        if wasActive {
            onEvent?(.stopped, epochToken)
        }

        lock.withLock {
            converter = nil
            hardwareFormat = nil
            pendingRebuild = nil
            pendingFormatChange = nil
        }
    }

    /// One hardware rate's conversion chain (mono input format + converter to the 24 kHz mono target).
    private struct Conversion {
        let mono: AVAudioFormat
        let converter: AVAudioConverter?
    }

    /// Every native call runs inside the boundary's Objective-C catching frame (v1.17 R4). The fixed
    /// target goes through NativePCM; the hardware-rate format and the converter keep v1.16's
    /// constructors (same acceptance). Nil: the input format is unavailable (v1.16's `mono_format`).
    private func conversion(rate: Double) throws -> Conversion? {
        let target = try headsetNative.call("target_format") {
            try NativePCM.format(.pcmFormatFloat32, rate: AudioRecorder.sampleRate, channels: 1, interleaved: false)
        }
        guard let mono = try headsetNative.call("input_format", {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        }) else { return nil }
        return Conversion(mono: mono, converter: try headsetNative.call("converter") { makeConverter(mono, target) })
    }

    /// One note per failing stage until a buffer converts again (stage + exception name, never audio).
    private func nativeFailed(_ error: Error) {
        let failure = HeadsetNativeFailure.wrap(error)
        guard headsetNative.failed(failure) else { return }
        note("headset_native_error backend=auhal stage=\(failure.stage) \(failure.field)")
    }

    /// Worker: rebuild the chain a caught native exception left unbuilt. A repeat exception stays
    /// pending (retried next tick, noted once); an unavailable format/converter reports v1.16's
    /// `converterFailed` once and stops retrying.
    private func rebuildAfterNativeFault() {
        guard let rate = lock.withLock({ _isRunning ? pendingRebuild : nil }) else { return }
        let built: Conversion?
        do { built = try conversion(rate: rate) } catch { nativeFailed(error); return }
        let emit: CaptureEpoch? = lock.withLock {
            guard _isRunning, pendingRebuild == rate else { return nil }
            pendingRebuild = nil
            if let built { hardwareFormat = built.mono }
            converter = built?.converter
            guard converter == nil, !converterFailedReported else { return nil }
            converterFailedReported = true
            return epoch
        }
        if let emit { onEvent?(.converterFailed, emit) }
    }

    /// Real-time thread: no locks, no allocation, no object retains — the context copies into a
    /// preallocated slot stamped with the current session number and counts the callback.
    private func makeRenderSink() -> HALRenderSink {
        let context = self.context
        return { pointer, count, hostTime in context.store(pointer, count, hostTime) }
    }

    private func startWorker() {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + workerInterval, repeating: workerInterval)
        timer.setEventHandler { [weak self] in self?.drain() }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    /// Offline harness (tests only): one worker drain, synchronously. No device, timer tick or audio.
    func offlineDrain() { worker.sync { drain() } }

    private func drain() {
        rebuildAfterNativeFault()
        let retry = lock.withLock { () -> HALStreamFormat? in
            defer { pendingFormatChange = nil }
            return _isRunning ? pendingFormatChange : nil
        }
        if let retry { handleFormatChange(driver.currentFormat() ?? retry) }
        guard let (format, token, currentSession) = lock.withLock({ () -> (AVAudioFormat, CaptureEpoch, Int)? in
            guard let format = self.hardwareFormat, let epoch = self.epoch, _isRunning else {
                return nil
            }
            return (format, epoch, session)
        }) else { return }

        // Callback stall check: the IO thread only counts; the worker timestamps what it saw.
        let now = clock()
        let callbacks = context.callbacks.load(ordering: .acquiring)
        let shouldReportStall = lock.withLock { () -> Bool in
            guard _isRunning else { return false }
            if callbacks != seenCallbacks {
                seenCallbacks = callbacks
                _lastCallbackTime = now
                callbacksStoppedReported = false
            }
            let last = _lastCallbackTime ?? startTime ?? now
            if now - last >= Self.callbackStall {
                if !callbacksStoppedReported {
                    callbacksStoppedReported = true
                    return true
                }
            }
            return false
        }
        if shouldReportStall {
            onEvent?(.callbacksStopped, token)
        }

        // Format change check if driver.currentFormat() differs from converter rate
        if let curFmt = driver.currentFormat() {
            if curFmt.sampleRate != format.sampleRate || curFmt.channels != Int(format.channelCount) {
                handleFormatChange(curFmt)
            }
        }

        let isInvalid = lock.withLock { isFormatInvalid }
        var currentConverter = lock.withLock { converter }

        // Drain slots. The input copy runs inside the ring's slot closure: a native exception is caught
        // there, the slot is still released (read index advanced) and counted, and the buffer is dropped.
        var slotFailure: Error?
        while let (frames, hostTime, slotSession) = context.nextSlot({ pointer, count -> AVAudioPCMBuffer? in
            do {
                guard let buffer = try headsetNative.call("input_buffer", {
                          AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
                      }),
                      let channel = buffer.floatChannelData?[0] else { return nil }
                channel.update(from: pointer, count: count)
                buffer.frameLength = AVAudioFrameCount(count)
                return buffer
            } catch {
                slotFailure = error
                return nil
            }
        }) {
            if let failure = slotFailure {
                slotFailure = nil
                nativeFailed(failure)
            }
            // Late frames from an earlier start are dropped
            guard slotSession == currentSession else { continue }

            lock.withLock {
                _counters.callback()
            }

            guard !isInvalid, let input = frames, let converter = currentConverter else { continue }

            let out: AVAudioPCMBuffer
            do {
                out = try headsetNative.call("output_buffer") { () throws -> AVAudioPCMBuffer in
                    let target = converter.outputFormat
                    let ratio = target.sampleRate / format.sampleRate
                    return try NativePCM.buffer(target, capacity: Int(ceil(Double(input.frameLength) * ratio)) + 128)
                }
            } catch {
                nativeFailed(error)
                continue
            }

            var fed = false
            var error: NSError?
            do {
                try headsetNative.call("convert") {
                    _ = converter.convert(to: out, error: &error) { _, status in
                        if fed { status.pointee = .noDataNow; return nil }
                        fed = true
                        status.pointee = .haveData
                        return input
                    }
                }
            } catch {
                // A converter that raised mid-conversion is never reused: rebuild it now for the
                // following slots (still pending for the next drain if the rebuild faults too).
                lock.withLock {
                    if self.converter === converter { self.converter = nil; pendingRebuild = hardwareFormat?.sampleRate }
                }
                nativeFailed(error)
                rebuildAfterNativeFault()
                currentConverter = lock.withLock { self.converter }
                continue
            }

            if let error {
                note("headset_convert_error=\(error.domain):\(error.code)")
                let shouldEmitFailed = lock.withLock { () -> Bool in
                    guard !converterFailedReported else { return false }
                    converterFailedReported = true
                    return true
                }
                if shouldEmitFailed {
                    onEvent?(.converterFailed, token)
                }
                continue
            }

            guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { continue }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))

            let start: TimeInterval
            if hostTime != 0 {
                start = AVAudioTime.seconds(forHostTime: hostTime)
            } else {
                start = clock() - Double(input.frameLength) / format.sampleRate
            }

            if headsetNative.recovered() { note("headset_native_recovered=1 backend=auhal") }
            let deliver: (([Float], TimeInterval, CaptureEpoch) -> Void)? = lock.withLock {
                guard _isRunning, epoch === token else { return nil }
                _counters.frames(chunk)
                return onFrames
            }
            deliver?(chunk, start, token)
        }
    }

    private func handleDeviceOrFormatChange() {
        guard lock.withLock({ _isRunning }) else { return }
        guard let deviceID = lock.withLock({ self.deviceID }) else { return }

        if !driver.isAlive(device: deviceID) {
            let shouldEmit = lock.withLock { () -> Bool in
                guard !deviceLostReported else { return false }
                deviceLostReported = true
                return true
            }
            if shouldEmit, let token = lock.withLock({ self.epoch }) {
                onEvent?(.deviceLost, token)
            }
        }

        if let curFmt = driver.currentFormat() {
            handleFormatChange(curFmt)
        }
    }

    private func handleFormatChange(_ newFormat: HALStreamFormat) {
        guard lock.withLock({ _isRunning }) else { return }
        guard let token = lock.withLock({ self.epoch }) else { return }

        if newFormat.sampleRate <= 0 || newFormat.channels <= 0 {
            let shouldEmit = lock.withLock { () -> Bool in
                isFormatInvalid = true
                guard !formatInvalidReported else { return false }
                formatInvalidReported = true
                return true
            }
            if shouldEmit {
                let gen = lock.withLock { _formatGeneration }
                onEvent?(.formatInvalid(generation: gen), token)
            }
            return
        }

        let needsUpdate = lock.withLock { () -> Bool in
            guard let cur = hardwareFormat else { return true }
            return cur.sampleRate != newFormat.sampleRate ||
                   Int(cur.channelCount) != newFormat.channels ||
                   isFormatInvalid
        }

        guard needsUpdate else { return }

        // v1.17 (R4): the whole chain is built (guarded) before the unit is reconfigured. A native exception
        // drops the old-rate converter (it would garble the new rate) and keeps the old hardware format;
        // the chain is marked mismatched (`isFormatInvalid`: no slot is converted, the retry always rebuilds)
        // and the worker retries the change at the top of its next drain.
        let built: Conversion?
        do { built = try conversion(rate: newFormat.sampleRate) } catch {
            lock.withLock { converter = nil; isFormatInvalid = true; pendingFormatChange = newFormat }
            nativeFailed(error)
            return
        }
        guard let mono = built?.mono else {
            let shouldEmit = lock.withLock { () -> Bool in
                guard !converterFailedReported else { return false }
                converterFailedReported = true
                return true
            }
            if shouldEmit {
                onEvent?(.converterFailed, token)
            }
            return
        }

        do {
            let sink = makeRenderSink()
            try driver.configure(clientRate: newFormat.sampleRate, channels: newFormat.channels, render: sink)
        } catch {
            note("headset_reconfigure_error=\(error)")
        }

        let conv = built?.converter
        let (gen, shouldEmitConverterFailed) = lock.withLock { () -> (Int, Bool) in
            _formatGeneration += 1
            hardwareFormat = mono
            converter = conv
            pendingRebuild = nil
            pendingFormatChange = nil
            isFormatInvalid = false
            formatInvalidReported = false
            var emitFailed = false
            if conv == nil {
                if !converterFailedReported {
                    converterFailedReported = true
                    emitFailed = true
                }
            } else {
                converterFailedReported = false
            }
            return (_formatGeneration, emitFailed)
        }

        if shouldEmitConverterFailed {
            onEvent?(.converterFailed, token)
        }
        onEvent?(.formatChanged(generation: gen, sampleRate: newFormat.sampleRate, channels: newFormat.channels), token)
    }
}

/// Preallocated lock-free ring of mono slots for the real-time callback (as BuiltinRenderContext):
/// each slot is stamped with the session number current when it was rendered.
final class HeadsetRenderContext: @unchecked Sendable {
    static let slots = 64
    static let maxFrames = 16_384

    private let slotFrames: UnsafeMutablePointer<Float>
    private let slotCounts: UnsafeMutablePointer<Int>
    private let slotHostTimes: UnsafeMutablePointer<UInt64>
    private let slotSessions: UnsafeMutablePointer<Int>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    /// Every callback, stored or dropped (the stall check reads it).
    let callbacks = Atomic<Int>(0)
    let session = Atomic<Int>(0)

    init() {
        slotFrames = .allocate(capacity: Self.slots * Self.maxFrames)
        slotFrames.initialize(repeating: 0, count: Self.slots * Self.maxFrames)
        slotCounts = .allocate(capacity: Self.slots)
        slotCounts.initialize(repeating: 0, count: Self.slots)
        slotHostTimes = .allocate(capacity: Self.slots)
        slotHostTimes.initialize(repeating: 0, count: Self.slots)
        slotSessions = .allocate(capacity: Self.slots)
        slotSessions.initialize(repeating: 0, count: Self.slots)
    }

    deinit {
        slotFrames.deallocate()
        slotCounts.deallocate()
        slotHostTimes.deallocate()
        slotSessions.deallocate()
    }

    /// Real-time thread: no allocation, no locks.
    func store(_ pointer: UnsafePointer<Float>, _ count: Int, _ hostTime: UInt64) {
        callbacks.wrappingAdd(1, ordering: .releasing)
        guard count > 0, count <= Self.maxFrames else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let w = written.load(ordering: .relaxed)
        guard w - read.load(ordering: .acquiring) < Self.slots else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let slot = w % Self.slots
        (slotFrames + slot * Self.maxFrames).update(from: pointer, count: count)
        slotCounts[slot] = count
        slotHostTimes[slot] = hostTime
        slotSessions[slot] = session.load(ordering: .acquiring)
        written.store(w + 1, ordering: .releasing)
    }

    /// Worker: the oldest filled slot, copied out by `copy`, with its host time and session.
    func nextSlot<T>(_ copy: (UnsafePointer<Float>, Int) -> T?) -> (T?, UInt64, Int)? {
        let r = read.load(ordering: .relaxed)
        guard r < written.load(ordering: .acquiring) else { return nil }
        let slot = r % Self.slots
        let result = copy(UnsafePointer(slotFrames + slot * Self.maxFrames), slotCounts[slot])
        let host = slotHostTimes[slot]
        let stamped = slotSessions[slot]
        read.store(r + 1, ordering: .releasing)
        return (result, host, stamped)
    }
}
