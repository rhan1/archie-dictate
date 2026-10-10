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
    public var onPCMChunk: (([Int16]) -> Void)? {
        get { lock.withLock { pcmCallback } }
        set { lock.withLock { pcmCallback = newValue } }
    }
    private var pcmCallback: (([Int16]) -> Void)?
    private var pendingPCM: [Int16] = []

    /// What the capture did, for the per-dictation stderr timeline.
    public struct CaptureStats {
        public var device = ""
        public var startFormat = ""
        public var engineStartMs = 0
        public var firstBufferMs: Int?
        public var formatChanges = 0
        public var configChanges = 0
        public var bridgeMs: Int?
        public var bridgeSource = "none"
        public var bridgeReason: String?
        /// Second tap → first kept frames (0 when the first-tap ring already held them).
        public var tap2ToFirstKeptMs: Int?
        /// v1.7: the headset went digital-zero mid-dictation and the built-in took over again.
        public var bridgeSwitchback = 0
        /// v1.7: the one headset restart's result (`signal` | `still_silent`), when one ran.
        public var headsetRestart: String?
    }
    public private(set) var stats = CaptureStats()
    /// Called on the main queue when the first audio buffer arrives after
    /// `start()` (a Bluetooth headset can take ~1.6 s to deliver it).
    public var onFirstBuffer: (() -> Void)?
    public var onCaptureFailure: (() -> Void)?
    public var isRunning: Bool {
        let state = lock.withLock { (captureRunning, engine, restarting && restartEpoch === engineEpoch) }
        if state.2 { return true }    // H2: this dictation's one headset restart is in flight
        return state.0 && ((try? captureObjC { state.1?.isRunning ?? false }) ?? false)
    }
    public var isAllocated: Bool { lock.withLock { engine != nil || builtin?.isAllocated == true } }
    /// A short dictation can finish through the bridge while headset startup is
    /// still in flight; its captured samples are already in the shared pipeline.
    public var bridgeHasAudio: Bool {
        lock.withLock { feed.bridge.bridgeSource.hasPrefix("builtin") && !samples.isEmpty }
    }
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

    // Replaced (under lock) when its executor wedges; see CaptureExecutorWatch.
    private var builtin: AudioRecorder?
    // Arbitration + the first-tap pre-roll ring, serialized by `lock`.
    private var feed = CaptureFeed()
    private var bridgeConfigured = false
    private var watch = CaptureExecutorWatch()
    /// Built-in setup finishes before the headset start triggers its Bluetooth
    /// profile switch (D-b); a stuck setup never delays the headset longer.
    static let builtinSetupWait: TimeInterval = 0.25
    private var captureBoundary: TimeInterval?
    /// H4: executor-only, reset per start and per headset restart (a deferred recovery
    /// from an earlier generation never runs).
    private var recoveryThrottle = RecoveryThrottle()
    private var throttleGeneration = 0
    private var restarting = false
    private var restartEpoch = CaptureEpoch()
    // Internal converted-buffer handoff avoids independent chunkers/remainders.
    private var onConvertedBuffer: (([Float], TimeInterval) -> Void)?

    public convenience init() { self.init(bridgeEnabled: true) }
    private init(bridgeEnabled: Bool) {
        builtin = bridgeEnabled ? AudioRecorder(bridgeEnabled: false) : nil
    }

    /// Runs on the headset executor, and starts the built-in mic on its own executor
    /// BEFORE the potentially blocking Bluetooth profile transition (first ⌥ tap).
    private func configureBridge(device: MicChoice, epoch: CaptureEpoch) {
        guard lock.withLock({ builtin != nil && !bridgeConfigured }) else { return }
        let eligibility = device == .default ? (try? AudioDevices.bridgeEligibility()) : nil
        var abandonedMs: Int?
        let started: (AudioRecorder, CaptureEpoch)? = lock.withLock {
            guard engineEpoch === epoch, var current = builtin else { return nil }
            if let busy = current.wedgedMs {
                abandonedMs = busy
                current.release()
                current = AudioRecorder(bridgeEnabled: false)
                builtin = current
            }
            bridgeConfigured = true
            feed.start(defaultInput: eligibility?.0 ?? .other, hasBuiltin: eligibility?.1 ?? false, epoch: epoch)
            if let captureBoundary { _ = feed.recordingStarted(at: captureBoundary) }
            guard feed.bridge.state == .builtinOnly else {
                AppController.note("bridge_src=none reason=\(feed.bridge.skipReason ?? "cancelled")")
                return nil
            }
            return current.lock.withLock {
                current.onConvertedBuffer = { [weak self] chunk, time in
                    self?.acceptConverted(chunk, at: time, source: .builtin, epoch: epoch)
                }
                current.onCaptureFailure = { [weak self] in self?.bridgeFailed(epoch: epoch) }
                return (current, current.engineEpoch)
            }
        }
        if let abandonedMs { AppController.note("bridge_abandoned=1 busy_ms=\(abandonedMs)") }
        guard let (current, builtinEpoch) = started else { return }
        let ready = DispatchSemaphore(value: 0)
        current.enqueueStart(device: .builtIn, epoch: builtinEpoch) { [weak self] result in
            if case .failure(let error) = result { self?.bridgeFailed(epoch: epoch, error: error) }
            ready.signal()
        }
        _ = ready.wait(timeout: .now() + Self.builtinSetupWait)
    }

    private func bridgeFailed(epoch: CaptureEpoch, error: Error? = nil) {
        let failed: Bool? = lock.withLock {
            guard engineEpoch === epoch, feed.bridge.state != .off, feed.bridge.bridgeSource != "none",
                  feed.bridge.skipReason == nil else { return nil }
            let starting = feed.bridge.state == .builtinOnly
            feed.builtinFailed()
            builtin?.release()
            return starting
        }
        guard let starting = failed else { return }
        // After the headset took over (or a fallback) the built-in can no longer carry the dictation.
        guard starting else {
            AppController.note("bridge_builtin_lost=1 state=\(lock.withLock { feed.bridge.state })")
            // Decided on the headset executor, after any recovery or restart already in flight:
            // only a headset that is still not capturing then means nothing carries.
            onExecutor { [weak self] in
                guard let self, self.lock.withLock({ self.engineEpoch === epoch && !self.captureRunning }) else { return }
                AppController.note("bridge_nothing_carries=1")
                let callback = self.onCaptureFailure
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lock.withLock({ self.engineEpoch === epoch }) else { return }
                    callback?()
                }
            }
            return
        }
        var line = "bridge_src=none reason=builtin_start_failed"
        if let mismatch = error as? TapFormatPlan.Mismatch { line += " builtin_error=\(mismatch)" }
        else if let error = error as NSError? { line += " builtin_error=\(error.domain):\(error.code)" }
        AppController.note(line)
    }

    /// Every executor operation is watched: one that never returns marks it wedged.
    private func onExecutor(_ work: @escaping () -> Void) {
        engineQueue.async { [self] in
            lock.withLock { watch.began(at: ProcessInfo.processInfo.systemUptime) }
            defer { lock.withLock { watch.ended() } }
            work()
        }
    }
    /// How long the current executor operation has been stuck, once it counts as wedged.
    private var wedgedMs: Int? {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard watch.isWedged(at: now), let since = watch.busySince else { return nil }
            return Int((now - since) * 1000)
        }
    }

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
        // isAllocated includes the bridge for idle cleanup; this start needs
        // the headset's own engine, even when the built-in path is still live.
        if lock.withLock({ engine == nil }) || selectedDevice != device || tapInstalled { try rebuild() }
        selectedDevice = device
        configureBridge(device: device, epoch: startEpoch)
        lock.withLock {
            stats = CaptureStats()
            meter.clearBatch()
        }
        resetRecoveryThrottle()
        startedAt = DispatchTime.now()
        stats.device = device == .builtIn ? "built-in" : (AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown")
        if device == .builtIn { try captureObjC { try AudioDevices.selectBuiltIn(on: requireEngine().inputNode) } }
        registerConfigurationObserver()
        try installTapAndStart()
        // H3: AVAudioEngine binds a new input node to the system default (the headset
        // aggregate) before `selectBuiltIn` can run; it offers no way to pick the device
        // first, so the bind is checked and corrected after every start instead.
        if device == .builtIn, isBridgeChild, case .drift? = checkBuiltinPin() { throw RecorderError.builtinDrift }
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
        try await startAsync(device: device, requiredEpoch: lock.withLock { engineEpoch })
    }

    private func startAsync(device: MicChoice, requiredEpoch epoch: CaptureEpoch) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueueStart(device: device, epoch: epoch) { continuation.resume(with: $0) }
        }
    }

    private func enqueueStart(device: MicChoice, epoch: CaptureEpoch,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        onExecutor { [self] in
            do {
                guard lock.withLock({ engineEpoch === epoch }) else { throw CancellationError() }
                try start(device: device)
                guard lock.withLock({ engineEpoch === epoch }) else {
                    teardownEngine()
                    throw CancellationError()
                }
                completion(.success(()))
            } catch {
                teardownEngine()
                completion(.failure(error))
            }
        }
    }

    public func rebuildAsync() async throws {
        let epoch = lock.withLock { engineEpoch }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            onExecutor { [self] in
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
            self.onExecutor { [weak self] in
                self?.configurationChanged(identity: identity, epoch: epoch, deferred: nil)
            }
        }
    }

    /// Runs on the executor. The headset engine is throttled after a failed start (H4);
    /// the built-in child re-selects its device before any restart (H3).
    private func configurationChanged(identity: CaptureEpoch, epoch: CaptureEpoch, deferred: Int?) {
        let current = { self.recording && self.lock.withLock {
            self.engineIdentity === identity &&
            self.captureRunning && self.engineEpoch === epoch
        } }
        let builtinChild = selectedDevice == .builtIn
        if !builtinChild {
            let now = ProcessInfo.processInfo.systemUptime
            if let generation = deferred {
                guard generation == throttleGeneration, lock.withLock({ engineEpoch === epoch }) else { return }
                recoveryThrottle.deferredFired(at: now)
            } else if current() {
                switch recoveryThrottle.request(at: now) {
                case .now: break
                case .coalesced: return
                case .after(let wait):
                    AppController.note("config_recovery_backoff_ms=\(Int((wait * 1000).rounded()))")
                    let generation = throttleGeneration
                    engineQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
                        self?.onExecutor { [weak self] in
                            self?.configurationChanged(identity: identity, epoch: epoch, deferred: generation)
                        }
                    }
                    return
                }
            }
        }
        guard current() else { return }
        stats.configChanges += 1
        // The observer identity was checked before entry. Our own rebuild
        // changes the engine/active flags, so only the epoch gates recovery.
        var result = CaptureConfigurationRecovery.run(isCurrent: {
            self.lock.withLock { self.engineEpoch === epoch }
        }, retap: {
            try self.removeTap()
            if builtinChild {
                try captureObjC { self.engine?.stop() }
                try AudioDevices.selectBuiltIn(on: self.requireEngine().inputNode)
            }
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
            if !builtinChild { self.recoveryThrottle.startFailed(at: ProcessInfo.processInfo.systemUptime) }
        })
        if builtinChild, isBridgeChild, result == .retapped || result == .rebuilt, case .drift? = checkBuiltinPin() {
            // Never let the bridge child float onto the headset aggregate: release it instead.
            teardownEngine()
            result = .failed
        }
        if result == .retapped || result == .rebuilt {
            let activated = self.lock.withLock {
                CaptureConfigurationRecovery.activate(epoch: epoch, current: self.engineEpoch) {
                    self.captureRunning = true
                }
            }
            if activated { self.recording = true }
            else { self.teardownEngine() }
        }
        if result == .failed, !builtinChild {
            // v1.7: a headset that cannot recover is not a failed dictation while the built-in carries it.
            let carried: CaptureBridge.Event? = lock.withLock {
                guard engineEpoch === epoch else { return nil }
                let out = feed.headsetFailed()
                deliverLocked(out.frames)
                return out.event
            }
            if let carried {
                AppController.note("headset_engine_failed=1 builtin_carries=\(carried == .switchback ? "switchback" : "fallback")")
                Self.noteCarried(carried, reason: "headset_engine_failed")
                return
            }
        }
        if result == .failed {
            let callback = self.onCaptureFailure
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ self.engineEpoch === epoch }) else { return }
                callback?()
            }
        }
    }

    /// The built-in carries the rest of the dictation after a headset failure (bt-proof.sh reads this).
    private static func noteCarried(_ event: CaptureBridge.Event, reason: String) {
        AppController.note(event == .switchback ? "bridge_switchback=1 reason=\(reason)"
                                                 : "bridge_src=builtin_fallback reason=\(reason)")
    }

    private func resetRecoveryThrottle() {
        recoveryThrottle = RecoveryThrottle()
        throttleGeneration += 1
    }

    /// The built-in bridge engine (it has no bridge of its own).
    private var isBridgeChild: Bool { lock.withLock { builtin == nil } }

    /// H3: read back the child's AUHAL device; move it back to the built-in once if it drifted.
    @discardableResult private func checkBuiltinPin() -> BuiltinPin.Check? {
        guard let unit = engine?.inputNode.audioUnit, let expected = try? AudioDevices.builtInInput() else { return nil }
        // Correction = the full stopped-engine selection (selection on a running unit would
        // keep the previous device's client format, D-a), then read back again.
        let check = BuiltinPin.enforce(expected: expected, read: {
            try AudioDevices.currentDevice(of: self.requireEngine().inputNode.audioUnit ?? unit)
        }, write: { _ in
            try self.removeTap()
            try captureObjC { self.engine?.stop() }
            try AudioDevices.selectBuiltIn(on: self.requireEngine().inputNode)
            try self.installTapAndStart()
        })
        AppController.note(check.note)
        return check
    }

    /// H2: one clean restart so coreaudiod re-requests the dropped eSCO link. The built-in
    /// child is pinned to its own device, so stopping this engine drops our Bluetooth IO to 0.
    private func restartHeadset(epoch: CaptureEpoch) {
        onExecutor { [self] in
            guard lock.withLock({ engineEpoch === epoch && captureRunning }), engine != nil else { return }
            lock.withLock { restarting = true; restartEpoch = epoch }
            defer { lock.withLock { restarting = false } }
            resetRecoveryThrottle()
            // Same shape as a cold start: a fresh engine, never the stopped one (its input
            // format reads 0 Hz while the headset is back on A2DP).
            let outcome = HeadsetRestart.perform(stop: { self.teardownEngine() },
                isRunningSomewhere: { AudioDevices.defaultInputIsRunningSomewhere() },
                sleep: { Thread.sleep(forTimeInterval: $0) }, start: {
                guard self.lock.withLock({ self.engineEpoch === epoch }) else { throw CancellationError() }
                try self.rebuild()
                try self.installTapAndStart()
                let activated = self.lock.withLock {
                    CaptureConfigurationRecovery.activate(epoch: epoch, current: self.engineEpoch) {
                        self.captureRunning = true
                    }
                }
                guard activated else { self.teardownEngine(); throw CancellationError() }
                self.recording = true
            }, note: { error in
                self.teardownEngine()
                AppController.note("headset_restart_error=\(error as NSError)")
            })
            let carried: (nothing: Bool, event: CaptureBridge.Event?) = lock.withLock {
                guard engineEpoch === epoch else { return (false, nil) }
                feed.headsetRestarted(started: outcome.started)
                guard !outcome.started else { return (false, nil) }
                let out = feed.headsetFailed()
                deliverLocked(out.frames)
                return (out.event == nil, out.event)
            }
            // Notes reach the host's sink: never under `lock`.
            if let event = carried.event { Self.noteCarried(event, reason: "headset_restart_failed") }
            if carried.nothing {
                let callback = onCaptureFailure
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lock.withLock({ self.engineEpoch === epoch }) else { return }
                    callback?()
                }
            }
            AppController.note("headset_restart=1 idle=\(outcome.deviceIdle ? 1 : 0) waited_ms=\(outcome.waitedMs) started=\(outcome.started ? 1 : 0)")
        }
    }

    private func requireEngine() throws -> AVAudioEngine {
        guard let engine else { throw RecorderError.noInput }
        return engine
    }

    private func installTapAndStart() throws {
        try captureObjC {
            let plan = try TapFormatPlan.run(device: selectedDevice, formats: {
                let input = try requireEngine().inputNode
                let hardware = input.inputFormat(forBus: 0), output = input.outputFormat(forBus: 0)
                return (TapFormatPlan.Format(sampleRate: hardware.sampleRate, channels: hardware.channelCount),
                        TapFormatPlan.Format(sampleRate: output.sampleRate, channels: output.channelCount))
            }, align: {
                try AudioDevices.alignClientFormat(on: requireEngine().inputNode)
            }, rebuild: {
                try rebuild()
                if selectedDevice == .builtIn { try AudioDevices.selectBuiltIn(on: requireEngine().inputNode) }
            })
            let input = try requireEngine().inputNode
            let hardware = input.inputFormat(forBus: 0)
            if case .ready(aligned: true, _) = plan {
                AppController.note("builtin_format_aligned=1 fmt=\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch")
            }
            if stats.startFormat.isEmpty {
                stats.startFormat = "\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch"
            }
            lock.withLock { converter = AVAudioConverter(from: hardware, to: targetFormat) }
            let token = CaptureEpoch()
            lock.withLock { tapEpoch = token }
            tapInstalled = true // remove even if installTap partially changes state then raises
            input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, time in
                self?.consume(buffer, time: time, epoch: token)
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

    /// Reset the shared 24 kHz pipeline at the recording boundary (second tap).
    /// The engines may already be running (started on the first ⌥ tap): keep the
    /// ring's audio from boundary − 150 ms; earlier pre-roll is discarded.
    public func resetCapture() {
        let kept: Int = lock.withLock {
            let boundary = ProcessInfo.processInfo.systemUptime
            captureBoundary = boundary
            let preRoll = feed.recordingStarted(at: boundary)
            samples.removeAll(keepingCapacity: true)
            samples.append(contentsOf: preRoll)
            pendingPCM = WAVEncoder.pcm16(from: preRoll)
            levelTimer?.cancel()
            levelTimer = nil
            meter.clearBatch()
            return preRoll.count
        }
        if kept > 0 { AppController.note("tap2_to_first_kept_buffer_ms=0 kept_src=ring preroll_frames=\(kept)") }
    }

    @discardableResult public func stop() -> [Float] {
        // Invalidates a queued/in-flight start without waiting for AVAudioEngine.
        lock.lock()
        engineEpoch = CaptureEpoch()
        tapEpoch = CaptureEpoch()
        stats.bridgeMs = feed.bridge.bridgeMs
        stats.bridgeSource = feed.bridge.bridgeSource
        stats.bridgeReason = feed.bridge.reason
        stats.tap2ToFirstKeptMs = feed.bridge.firstKeptMs
        // A second stop (idle-guard release) must not erase the first one's results.
        let live = feed.bridge.state != .off
        if live {
            stats.bridgeSwitchback = feed.bridge.switchbacks
            stats.headsetRestart = feed.bridge.restart?.result
        }
        let restartResult = live ? feed.bridge.restart?.result : nil
        feed.cancel() // a lone tap's ring is discarded here
        bridgeConfigured = false
        captureBoundary = nil
        captureRunning = false
        converter = nil
        let captured = samples
        let remainder = pendingPCM
        let callback = pcmCallback
        samples.removeAll()
        pendingPCM.removeAll()
        levelTimer?.cancel()
        levelTimer = nil
        meter.clearBatch()
        var abandonedMs: Int?
        if let current = builtin {
            current.release()
            // Its queued teardown would wait forever behind a wedged call (D-b).
            if let busy = current.wedgedMs { abandonedMs = busy; builtin = AudioRecorder(bridgeEnabled: false) }
        }
        lock.unlock()
        if let abandonedMs { AppController.note("bridge_abandoned=1 busy_ms=\(abandonedMs)") }
        if let restartResult { AppController.note("headset_restart=1 result=\(restartResult)") }
        if !remainder.isEmpty { callback?(remainder) }
        onExecutor { [self] in teardownEngine() }
        return captured
    }

    private func consume(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, epoch token: CaptureEpoch) {
        // The converter must match the buffers actually arriving: a format
        // change under a live tap otherwise yields garbled (resampled-wrong) audio.
        let capture = lock.withLock { (engineEpoch, onConvertedBuffer) }
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
        // AVAudioTime is in the same host-clock domain for both engines.
        let hostStart = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) :
            ProcessInfo.processInfo.systemUptime - Double(chunk.count) / Self.sampleRate
        guard lock.withLock({ captureRunning && tapEpoch === token && engineEpoch === capture.0 }) else { return }
        if let callback = capture.1 { callback(chunk, hostStart) }
        else { acceptConverted(chunk, at: hostStart, source: .headset, epoch: capture.0, tap: token) }
    }

    /// Arbitration, accumulation, PCM delivery and meter updates share this lock.
    /// A switch cannot overtake a built-in buffer's delivery to the chunker.
    private func acceptConverted(_ converted: [Float], at time: TimeInterval,
                                 source: CaptureBridge.Source, epoch: CaptureEpoch,
                                 tap: CaptureEpoch? = nil) {
        lock.lock()
        guard engineEpoch === epoch, tap == nil || tapEpoch === tap else { lock.unlock(); return }
        let decision = feed.accept(converted, source: source, at: time,
                                   arrivedAt: ProcessInfo.processInfo.systemUptime, epoch: epoch)
        deliverLocked(decision.frames)
        let bridgeMs = feed.bridge.bridgeMs, builtinFrames = feed.bridge.builtinFrames
        let firstKeptMs = decision.firstKept ? feed.bridge.firstKeptMs : nil
        // v1.7: the built-in keeps running after the headset takes over (it is the
        // switchback source) and is released when the dictation stops.
        lock.unlock()
        if decision.restartHeadset { restartHeadset(epoch: epoch) }
        switch decision.event {
        case .fallback?: AppController.note("bridge_src=builtin_fallback reason=headset_digital_silence")
        case .switchback?: AppController.note("bridge_switchback=1")
        case nil: break
        }
        if let firstKeptMs {
            AppController.note("tap2_to_first_kept_buffer_ms=\(firstKeptMs) kept_src=\(source == .builtin ? "builtin" : "headset")")
        }
        if decision.releaseBuiltin {
            if let bridgeMs { AppController.note("bridge_ms=\(bridgeMs) bridge_src=builtin builtin_frames=\(builtinFrames)") }
        }
    }

    /// Accumulation, PCM delivery and meter updates for frames the feed kept. Caller holds `lock`.
    private func deliverLocked(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
        // Accumulate even before the transcriber attaches; nothing after the
        // recording boundary is discarded during asynchronous hardware startup.
        pendingPCM.append(contentsOf: WAVEncoder.pcm16(from: chunk))
        if let callback = pcmCallback {
            while pendingPCM.count >= Self.chunkSamples {
                let pcm = Array(pendingPCM.prefix(Self.chunkSamples))
                pendingPCM.removeFirst(Self.chunkSamples)
                callback(pcm)
            }
        }
        if !chunk.isEmpty {
            meter.append(db: WisprLevel.db(samples: chunk), at: ProcessInfo.processInfo.systemUptime)
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

    public enum RecorderError: Error { case noInput, builtinDrift }
}
