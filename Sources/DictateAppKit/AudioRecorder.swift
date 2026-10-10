import AVFoundation
import DictateCore

/// AVAudioEngine capture, converted live to 24 kHz mono pcm16 (the rate the
/// batch STT fallbacks receive) and kept in memory only. Nothing is ever written to disk.
public final class AudioRecorder: CaptureEngine {
    public static let sampleRate: Double = 24_000
    /// 100 ms of pcm16 per streamed chunk (v1.1 A1).
    public static let chunkSamples = 2_400

    /// Called on the main queue with the mean level of each nonempty 150 ms batch.
    public var onLevel: ((Double) -> Void)?
    /// Called on the AUDIO thread with each 100 ms pcm16 chunk, and once more
    /// from `stop()` with the remainder. Must be thread-safe.
    public var onPCMChunk: (([Int16]) -> Void)?
    private var pendingPCM: [Int16] = []

    /// What the capture did, for the per-dictation stderr timeline.
    public struct CaptureStats {
        public var device = ""
        public var startFormat = ""
        public var engineStartMs = 0
        public var firstBufferMs: Int?
        public var formatChanges = 0
        public var configChanges = 0
    }
    public private(set) var stats = CaptureStats()
    /// Called on the main queue when the first audio buffer arrives after
    /// `start()` (a Bluetooth headset can take ~1.6 s to deliver it).
    public var onFirstBuffer: (() -> Void)?
    public var onCaptureFailure: (() -> Void)?
    public var isRunning: Bool {
        let state = lock.withLock { (captureRunning, engine) }
        return state.0 && ((try? captureObjC { state.1?.isRunning ?? false }) ?? false)
    }
    public var isAllocated: Bool { lock.withLock { engine != nil } }
    private var captureRunning = false
    private var startedAt = DispatchTime.now()
    private var recording = false
    private var configObserver: NSObjectProtocol?

    private var engine: AVAudioEngine?
    private var engineIdentity = CaptureEpoch()
    private var tapInstalled = false
    private var selectedDevice: MicChoice = .default
    private let engineQueue = DispatchQueue(label: "dictate.capture.engine")
    private var engineEpoch = CaptureEpoch()
    private var tapEpoch = CaptureEpoch()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!
    private var meter = WisprLevel() // persists for this app-lifetime recorder
    private var levelTimer: DispatchSourceTimer?

    public init() {}

    public static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    /// Synchronous protocol entry point; controller uses startAsync on engineQueue.
    public func start(device: MicChoice = .default) throws {
        if isRunning, selectedDevice == device { return }
        let startEpoch = lock.withLock { engineEpoch }
        if !isAllocated || selectedDevice != device || tapInstalled { try rebuild() }
        selectedDevice = device
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            pendingPCM.removeAll()
            stats = CaptureStats()
            meter.clearBatch()
        }
        startedAt = DispatchTime.now()
        stats.device = device == .builtIn ? "built-in" : (AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown")
        if device == .builtIn { try captureObjC { try AudioDevices.selectBuiltIn(on: requireEngine().inputNode) } }
        registerConfigurationObserver()
        try installTapAndStart()
        stats.engineStartMs = elapsedMs()
        let activated = lock.withLock {
            guard engineEpoch === startEpoch else { return false }
            captureRunning = true
            return true
        }
        guard activated else { throw CancellationError() }
        recording = true
    }

    /// Serial background execution keeps Bluetooth engine startup off the main thread.
    /// stop() replaces the epoch immediately; a late start is torn down before returning.
    public func startAsync(device: MicChoice) async throws {
        let epoch = lock.withLock { engineEpoch }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async { [self] in
                do {
                    guard lock.withLock({ engineEpoch === epoch }) else { throw CancellationError() }
                    try start(device: device)
                    guard lock.withLock({ engineEpoch === epoch }) else {
                        teardownEngine()
                        throw CancellationError()
                    }
                    continuation.resume()
                } catch {
                    teardownEngine()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func rebuildAsync() async throws {
        let epoch = lock.withLock { engineEpoch }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            engineQueue.async { [self] in
                do {
                    guard lock.withLock({ engineEpoch === epoch }) else { throw CancellationError() }
                    try rebuild()
                    guard lock.withLock({ engineEpoch === epoch }) else { throw CancellationError() }
                    continuation.resume()
                } catch { teardownEngine(); continuation.resume(throwing: error) }
            }
        }
    }

    public func rebuild() throws {
        teardownEngine()
        let fresh = try captureObjC { AVAudioEngine() }
        lock.withLock { engine = fresh; engineIdentity = CaptureEpoch() }
        registerConfigurationObserver() // always observes the replacement, never the old engine
    }

    private func registerConfigurationObserver() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        guard let observedEngine = engine else { return }
        let identity = lock.withLock { engineIdentity }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: observedEngine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let epoch = self.lock.withLock { self.engineEpoch }
            self.engineQueue.async { [weak self] in
                guard let self else { return }
                let current = { self.recording && self.lock.withLock {
                    self.engineIdentity === identity &&
                    self.captureRunning && self.engineEpoch === epoch
                } }
                guard current() else { return }
                self.stats.configChanges += 1
                // The observer identity was checked before entry. Our own rebuild
                // changes the engine/active flags, so only the epoch gates recovery.
                let result = CaptureConfigurationRecovery.run(isCurrent: {
                    self.lock.withLock { self.engineEpoch === epoch }
                }, retap: {
                    try self.removeTap()
                    try self.installTapAndStart()
                }, rebuildAndStart: {
                    let device = self.selectedDevice
                    try self.rebuild()
                    if device == .builtIn {
                        try AudioDevices.selectBuiltIn(on: self.requireEngine().inputNode)
                    }
                    try self.installTapAndStart()
                }, teardown: { self.teardownEngine() }, note: {
                    AppController.note("config_retap_error=\($0 as NSError)")
                })
                if result == .retapped || result == .rebuilt {
                    let activated = self.lock.withLock {
                        CaptureConfigurationRecovery.activate(epoch: epoch, current: self.engineEpoch) {
                            self.captureRunning = true
                        }
                    }
                    if activated { self.recording = true }
                    else { self.teardownEngine() }
                }
                if result == .failed {
                    let callback = self.onCaptureFailure
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.lock.withLock({ self.engineEpoch === epoch }) else { return }
                        callback?()
                    }
                }
            }
        }
    }

    private func requireEngine() throws -> AVAudioEngine {
        guard let engine else { throw RecorderError.noInput }
        return engine
    }

    private func installTapAndStart(allowRebuild: Bool = true) throws {
        try captureObjC {
            let input = try requireEngine().inputNode
            let hardware = input.inputFormat(forBus: 0)
            let output = input.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0,
                  hardware.sampleRate == output.sampleRate, hardware.channelCount == output.channelCount else {
                if allowRebuild {
                    try rebuild()
                    if selectedDevice == .builtIn { try AudioDevices.selectBuiltIn(on: requireEngine().inputNode) }
                    try installTapAndStart(allowRebuild: false)
                    return
                }
                throw RecorderError.noInput
            }
            if stats.startFormat.isEmpty {
                stats.startFormat = "\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch"
            }
            lock.withLock { converter = AVAudioConverter(from: hardware, to: targetFormat) }
            let token = CaptureEpoch()
            lock.withLock { tapEpoch = token }
            tapInstalled = true // remove even if installTap partially changes state then raises
            input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
                self?.consume(buffer, epoch: token)
            }
            try requireEngine().prepare()
            try requireEngine().start()
        }
    }

    private func removeTap() throws {
        guard tapInstalled else { return }
        defer { tapInstalled = false; lock.withLock { tapEpoch = CaptureEpoch() } }
        try captureObjC { try requireEngine().inputNode.removeTap(onBus: 0) }
    }

    /// Continue cleanup after any individual exception, including a partial tap install.
    private func teardownEngine() {
        recording = false
        lock.withLock { captureRunning = false; converter = nil; tapEpoch = CaptureEpoch() }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        // Drop even a poisoned engine; replacing it here would allocate while idle.
        defer { lock.withLock { engine = nil; engineIdentity = CaptureEpoch() } }
        let calls: [() throws -> Void] = [
            { try self.removeTap() },
            { try captureObjC { self.engine?.stop() } },
            { try captureObjC { self.engine?.reset() } }
        ]
        CaptureConfigurationRecovery.teardown(calls) {
            AppController.note("mic_teardown_error=\($0 as NSError)")
        }
    }

    /// Uses the same serial teardown as stop; also invalidates in-flight starts.
    public func release() { _ = stop() }

    private func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
    }

    /// Stops capture and hands back everything recorded, as 16 kHz mono floats.
    /// Dictation begins on an engine that may already be running (pre-warmed on
    /// the first ⌥ tap): drop the pre-roll so only post-double-tap audio counts.
    public func resetCapture() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            pendingPCM.removeAll()
            levelTimer?.cancel()
            levelTimer = nil
            meter.clearBatch()
        }
    }

    @discardableResult public func stop() -> [Float] {
        // Invalidates a queued/in-flight start without waiting for AVAudioEngine.
        lock.lock()
        engineEpoch = CaptureEpoch()
        tapEpoch = CaptureEpoch()
        captureRunning = false
        converter = nil
        let captured = samples
        let remainder = pendingPCM
        samples.removeAll()
        pendingPCM.removeAll()
        levelTimer?.cancel()
        levelTimer = nil
        meter.clearBatch()
        lock.unlock()
        if !remainder.isEmpty { onPCMChunk?(remainder) }
        engineQueue.async { [self] in teardownEngine() }
        return captured
    }

    private func consume(_ buffer: AVAudioPCMBuffer, epoch token: CaptureEpoch) {
        // The converter must match the buffers actually arriving: a format
        // change under a live tap otherwise yields garbled (resampled-wrong) audio.
        let converter: AVAudioConverter? = lock.withLock {
            guard captureRunning, tapEpoch === token else { return nil }
            if stats.firstBufferMs == nil {
                stats.firstBufferMs = elapsedMs()
                let epoch = engineEpoch
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lock.withLock({ self.engineEpoch === epoch && self.captureRunning && self.tapEpoch === token }) else { return }
                    // A valid prewarm buffer can be delivered after the second tap.
                    self.onFirstBuffer?()
                }
            }
            if let current = self.converter, current.inputFormat == buffer.format { return current }
            if self.converter != nil { stats.formatChanges += 1 }
            self.converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            return self.converter
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        var ready: [[Int16]] = []
        lock.lock()
        guard captureRunning, tapEpoch === token else { lock.unlock(); return }
        samples.append(contentsOf: chunk)
        if onPCMChunk != nil {
            pendingPCM.append(contentsOf: WAVEncoder.pcm16(from: chunk))
            while pendingPCM.count >= AudioRecorder.chunkSamples {
                ready.append(Array(pendingPCM.prefix(AudioRecorder.chunkSamples)))
                pendingPCM.removeFirst(AudioRecorder.chunkSamples)
            }
        }
        lock.unlock()
        for pcm in ready { onPCMChunk?(pcm) }

        guard !chunk.isEmpty else { return }
        let db = WisprLevel.db(samples: chunk)
        lock.withLock {
            guard captureRunning, tapEpoch === token else { return }
            let now = ProcessInfo.processInfo.systemUptime
            meter.append(db: db, at: now)
            if levelTimer == nil {
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + WisprLevel.batchSeconds, repeating: WisprLevel.batchSeconds)
                timer.setEventHandler { [weak self] in self?.postLevelBatch() }
                levelTimer = timer
                timer.resume()
            }
        }
    }

    private func postLevelBatch() {
        let mean = lock.withLock { meter.batch(at: ProcessInfo.processInfo.systemUptime) }
        if let mean { onLevel?(mean) }
    }

    public enum RecorderError: Error { case noInput }
}
