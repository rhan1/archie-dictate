import AVFoundation
import DictateCore

/// AVAudioEngine capture of the default input (the headset), plus — when the default input is
/// Bluetooth — the built-in microphone as an owned raw AUHAL (v1.8 L1, `BuiltinCaptureUnit`),
/// converted live to 24 kHz mono pcm16 (the rate the batch STT fallbacks receive) and kept in
/// memory only. Nothing is ever written to disk.
///
/// v1.8: an independent 100 ms health clock (L2) watches every carrying source and ends a
/// dictation that hears nothing with `mic_dead`; one Bluetooth recovery episode (L3) admits
/// every headset restart; PCM leaves the state lock in sequence order (GPT-6 B1).
/// v1.11 (L2): what a capture session is for, as written on its session-end line. Labels only:
/// a conversation captures exactly like a dictation.
public enum CaptureKind: String, Sendable { case dictation, conversation }

public final class AudioRecorder: CaptureEngine {
    public static let sampleRate: Double = 24_000
    /// 100 ms of pcm16 per streamed chunk (v1.1 A1).
    public static let chunkSamples = 2_400

    /// Called on the main queue with the mean level of each nonempty 150 ms batch.
    public var onLevel: ((Double) -> Void)?
    /// Called with each 100 ms pcm16 chunk in order, outside the recorder's state lock, and once
    /// more from `stop()` with the remainder. Must be thread-safe; it may call back into the recorder.
    public var onPCMChunk: (([Int16]) -> Void)? {
        get { lock.withLock { pcmCallback } }
        set { lock.withLock { pcmCallback = newValue } }
    }
    private var pcmCallback: (([Int16]) -> Void)?
    private var pendingPCM: [Int16] = []
    private let delivery = OrderedDelivery<[Int16]>()

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
        /// v1.11 (L4): `skipped` when it was requested but never ran.
        public var headsetRestart: String?
        /// v1.8: kept sample-time intervals (ms from the recording boundary) and speech sections.
        public var captureIntervals = "none"
        public var speechSections = 0
        public var recordingMs = 0
        public var builtinFramesAfterFallback = 0
        public var builtinBackend: String?
        /// v1.10 (L1): the engine operations this dictation performed on the headset, and the
        /// ones the hands-off window held back (`HeadsetIOGuard`).
        public var ioOps = HeadsetIOGuard(bluetooth: false).note
        public var ioHeld = HeadsetIOGuard(bluetooth: false).heldNote
        /// v1.11 (L4): the carrying source over time (`builtin:0-1106,headset:1106-15110`, ms from
        /// the second tap) and the ms the Bluetooth headset carried.
        public var carrier = "none"
        public var headsetCarriedMs = 0
        /// v1.11 (L4): `capture_intervals` hit CaptureEvidence's cap; its last interval absorbed the
        /// rest, so it is not coverage.
        public var captureIntervalsTruncated = false
        /// v1.11 (L2): the session's kind (the recorder's `kind` when it stopped).
        public var kind: CaptureKind = .dictation
        public init() {}

        /// The capture part of the session-end line (counts only), shared by Dictate and hosts:
        /// `kind=… recording_ms=… capture_intervals=… [capture_intervals_truncated=1] speech_sections=…
        /// builtin_frames_after_fallback=… [builtin_backend=…] carrier=… headset_carried_ms=… io_ops=… io_held=…`.
        public var sessionEndFields: String {
            var line = "kind=\(kind.rawValue) recording_ms=\(recordingMs) capture_intervals=\(captureIntervals)"
            if captureIntervalsTruncated { line += " capture_intervals_truncated=1" }
            line += " speech_sections=\(speechSections) builtin_frames_after_fallback=\(builtinFramesAfterFallback)"
            if let backend = builtinBackend { line += " builtin_backend=\(backend)" }
            line += " carrier=\(carrier) headset_carried_ms=\(headsetCarriedMs)"
            return line + " \(ioOps) \(ioHeld)"
        }
    }
    /// v1.11 (L2): set by a host before `startAsync`; written as `kind=` on the session-end line.
    public var kind: CaptureKind {
        get { lock.withLock { captureKind } }
        set { lock.withLock { captureKind = newValue } }
    }
    private var captureKind: CaptureKind = .dictation
    public private(set) var stats = CaptureStats()
    /// Called on the main queue when the first headset buffer arrives after `start()`
    /// (a Bluetooth headset can take ~1.6 s to deliver it).
    public var onFirstBuffer: (() -> Void)?
    /// v1.8: why capture ended on its own (`mic_dead` from the health clock, or an engine failure).
    public var onCaptureFailure: ((CaptureFailure) -> Void)?
    public var isRunning: Bool {
        let state = lock.withLock { (captureRunning, engine, restarting && restartEpoch === engineEpoch) }
        if state.2 { return true }    // H2: this dictation's headset restart is in flight
        return state.0 && ((try? captureObjC { state.1?.isRunning ?? false }) ?? false)
    }
    public var isAllocated: Bool { lock.withLock { engine != nil || builtinActive } }
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

    // v1.8 L1: the owned built-in unit, on its own serial queue (replaced when that queue wedges).
    private var builtin: BuiltinCapture
    private let makeBuiltin: () -> BuiltinCapture
    private var builtinQueue = DispatchQueue(label: "dictate.capture.builtin")
    private var builtinActive = false
    private var builtinDriftNoted = false
    // Arbitration, health and the first-tap pre-roll ring, serialized by `lock`.
    private var feed = CaptureFeed()
    private var bridgeConfigured = false
    private var watch = CaptureExecutorWatch()
    private var builtinWatch = CaptureExecutorWatch()
    /// Built-in setup finishes before the headset start triggers its Bluetooth
    /// profile switch (D-b); a stuck setup never delays the headset longer.
    static let builtinSetupWait: TimeInterval = 0.25
    private var captureBoundary: TimeInterval?
    // v1.8 L2: the health clock (never driven by tap callbacks).
    private let healthQueue = DispatchQueue(label: "dictate.capture.health")
    private var healthTimer: DispatchSourceTimer?
    // v1.8 L3: one recovery episode per dictation, across engine replacements (state under `lock`).
    private var episode = BluetoothRecoveryEpisode(bluetooth: false)
    /// v1.10 (L1): this dictation's engine operations and the hands-off window (state under `lock`).
    private var ioGuard = HeadsetIOGuard(bluetooth: false)
    /// The headset device the dictation started on: the busy check polls it, never a re-resolved default.
    private var headsetDevice: AudioDeviceID?
    private var restarting = false
    private var restartEpoch = CaptureEpoch()
    /// L3: the admitted attempt being verified (frames within 1 s), bound to its own token.
    /// v1.9: `firstSignal` = the first buffer with signal; zeros alone settle as `silent_frames`.
    private var verifying: (token: CaptureEpoch, since: TimeInterval, firstFrame: TimeInterval?, firstSignal: TimeInterval?)?
    /// A lifecycle retry the episode queued: `start()` begins it when the lifecycle runs it.
    private var lifecycleAttemptPending = false

    public convenience init() { self.init(builtin: { BuiltinCaptureUnit() }) }
    init(builtin make: @escaping () -> BuiltinCapture) {
        makeBuiltin = make
        builtin = make()
    }

    /// Runs on the headset executor, and starts the built-in unit on its own queue BEFORE the
    /// potentially blocking Bluetooth profile transition (first ⌥ tap).
    private func configureBridge(device: MicChoice, epoch: CaptureEpoch) {
        guard lock.withLock({ !bridgeConfigured }) else { return }
        let eligibility = device == .default ? (try? AudioDevices.bridgeEligibility()) : nil
        let bluetooth = eligibility?.0 == .bluetooth
        let headset = bluetooth ? AudioDevices.defaultInputDevice() : nil
        var abandonedMs: Int?
        let unit: BuiltinCapture? = lock.withLock {
            guard engineEpoch === epoch else { return nil }
            if let busy = builtinWedgedMsLocked() {
                abandonedMs = busy
                builtin = makeBuiltin()
                builtinQueue = DispatchQueue(label: "dictate.capture.builtin")
                builtinWatch = CaptureExecutorWatch()
            }
            bridgeConfigured = true
            feed.start(defaultInput: eligibility?.0 ?? .other, hasBuiltin: eligibility?.1 ?? false, epoch: epoch)
            episode = BluetoothRecoveryEpisode(bluetooth: bluetooth)
            ioGuard = HeadsetIOGuard(bluetooth: bluetooth)
            headsetDevice = headset
            builtinDriftNoted = false
            if let captureBoundary { _ = feed.recordingStarted(at: captureBoundary) }
            guard feed.bridge.state == .builtinOnly else { return nil }
            feed.sourceStarted(.builtin, at: ProcessInfo.processInfo.systemUptime)
            builtinActive = true
            return builtin
        }
        if let abandonedMs { AppController.note("bridge_abandoned=1 busy_ms=\(abandonedMs)") }
        guard let unit else {
            let reason = lock.withLock { engineEpoch === epoch ? feed.bridge.skipReason : nil }
            if let reason { AppController.note("bridge_src=none reason=\(reason)") }
            return
        }
        unit.onFrames = { [weak self] chunk, time, _ in
            self?.acceptConverted(chunk, at: time, source: .builtin, epoch: epoch)
        }
        unit.onDeviceLost = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { if self.engineEpoch === epoch { self.feed.deviceProblem(.builtin, .lost) } }
            AppController.note("bridge_device_check=lost")
        }
        let ready = DispatchSemaphore(value: 0)
        let queue = lock.withLock { builtinQueue }
        queue.async { [weak self] in
            guard let self else { ready.signal(); return }
            self.lock.withLock { self.builtinWatch.began(at: ProcessInfo.processInfo.systemUptime) }
            defer { self.lock.withLock { self.builtinWatch.ended() } }
            guard self.lock.withLock({ self.engineEpoch === epoch }) else { ready.signal(); return }
            do {
                try unit.start(epoch: epoch)
                let id = unit.expectedDeviceID.map(String.init) ?? "?"
                AppController.note("builtin_backend=\(unit.backend) device=\(id) \(unit.deviceCheck()?.note ?? "bridge_device_check=unreadable")")
                // stop() may have run while the unit was starting.
                if !self.lock.withLock({ self.engineEpoch === epoch }) { unit.stop() }
            } catch {
                self.bridgeFailed(epoch: epoch, error: error)
            }
            ready.signal()
        }
        _ = ready.wait(timeout: .now() + Self.builtinSetupWait)
    }

    /// The built-in unit could not start: the headset carries alone (today's behaviour).
    private func bridgeFailed(epoch: CaptureEpoch, error: Error) {
        let failed: Bool = lock.withLock {
            guard engineEpoch === epoch, feed.bridge.state != .off else { return false }
            builtinActive = false
            if feed.bridge.state == .builtinOnly { feed.builtinFailed() }
            else { feed.deviceProblem(.builtin, .lost) }
            return true
        }
        guard failed else { return }
        lock.withLock { builtin }.stop(epoch: epoch)
        var line = "bridge_src=none reason=builtin_start_failed"
        if let error = error as? BuiltinCaptureUnit.StartError { line += " builtin_error=\(error.description)" }
        else if let error = error as NSError? { line += " builtin_error=\(error.domain):\(error.code)" }
        AppController.note(line)
    }

    /// Stops `unit` only if it is still running for `epoch` (a reused unit is never stopped by stale cleanup).
    private func stopBuiltinUnit(_ unit: BuiltinCapture, queue: DispatchQueue, epoch: CaptureEpoch) {
        // The watch belongs to the current queue: cleanup on an abandoned queue never touches it.
        queue.async { [weak self] in
            self?.lock.withLock { if self?.builtinQueue === queue { self?.builtinWatch.began(at: ProcessInfo.processInfo.systemUptime) } }
            unit.stop(epoch: epoch)
            self?.lock.withLock { if self?.builtinQueue === queue { self?.builtinWatch.ended() } }
        }
    }

    private func builtinWedgedMsLocked() -> Int? {
        let now = ProcessInfo.processInfo.systemUptime
        guard builtinWatch.isWedged(at: now), let since = builtinWatch.busySince else { return nil }
        return Int((now - since) * 1000)
    }

    /// Every executor operation is watched: one that never returns marks it wedged.
    private func onExecutor(_ work: @escaping () -> Void) {
        engineQueue.async { [self] in
            lock.withLock { watch.began(at: ProcessInfo.processInfo.systemUptime) }
            defer { lock.withLock { watch.ended() } }
            work()
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
        // isAllocated includes the built-in unit for idle cleanup; this start needs
        // the headset's own engine, even when the built-in path is still live.
        if lock.withLock({ engine == nil }) || selectedDevice != device || tapInstalled { try rebuild() }
        selectedDevice = device
        configureBridge(device: device, epoch: startEpoch)
        let startedAt = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            stats = CaptureStats()
            meter.clearBatch()
            if engineEpoch === startEpoch { feed.sourceStarted(.headset, at: startedAt) }
        }
        self.startedAt = DispatchTime.now()
        stats.device = device == .builtIn ? "built-in" : (AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown")
        if device == .builtIn { try captureObjC { try AudioDevices.selectBuiltIn(on: requireEngine().inputNode) } }
        // L3: a lifecycle retry the episode queued is begun here, when it actually runs, after
        // re-checking the stable format (a notification during the lifecycle's wait moves it).
        let lifecycleAttempt: Bool = lock.withLock {
            defer { lifecycleAttemptPending = false }
            return lifecycleAttemptPending && engineEpoch === startEpoch
        }
        if lifecycleAttempt {
            if case .wait(let more) = lock.withLock({ episode.beginIfStable(at: ProcessInfo.processInfo.systemUptime) }) {
                Thread.sleep(forTimeInterval: min(more, BluetoothRecoveryEpisode.window))
                if case .wait = lock.withLock({ episode.beginIfStable(at: ProcessInfo.processInfo.systemUptime) }) {
                    lock.withLock { _ = episode.begin(at: ProcessInfo.processInfo.systemUptime, force: true) }   // bounded by the window
                }
            }
        }
        // Verification is armed BEFORE the hardware start: a frame during startup counts, and a
        // start that never returns still settles the attempt at its absolute deadline.
        if lock.withLock({ episode.isRunning && engineEpoch === startEpoch }) {
            verifyFrames(epoch: startEpoch, since: ProcessInfo.processInfo.systemUptime, path: .startRetry)
        }
        registerConfigurationObserver()
        try installTapAndStart()
        // The MicStartChain built-in path still uses AVAudioEngine: read its device back once.
        if device == .builtIn { checkBuiltinPin() }
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
                lock.withLock { if engineEpoch === epoch, episode.isRunning { episode.settled(.failed) } }
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
        // Creating the first engine is not a rebuild; replacing one is.
        lock.withLock { if engine != nil { ioGuard.record(.rebuild) } }
        teardownEngine()
        let fresh = try captureObjC { AVAudioEngine() }
        lock.withLock { engine = fresh; engineIdentity = CaptureEpoch() }
        registerConfigurationObserver() // always observes the replacement, never the old engine
    }

    /// v1.8 (L3): the lifecycle's start retry and first-buffer retry ask here first.
    public func recoveryAdmission(_ path: RecoveryPath) -> RecoveryAdmission {
        let now = ProcessInfo.processInfo.systemUptime
        let (epoch, bluetooth, builtinCarries) = lock.withLock {
            (engineEpoch, bridgeConfigured && episode.bluetooth, feed.health.status(.builtin, at: now) == .healthy)
        }
        guard bluetooth else { return .proceed(after: 0) }
        if path == .firstBuffer, builtinCarries {
            // The built-in carries: only the headset engine is restarted, by the episode.
            requestHeadsetRestart(epoch: epoch, path: .firstBuffer)
            return .skip
        }
        let admission: BluetoothRecoveryEpisode.Admission = lock.withLock {
            guard engineEpoch === epoch else { return .exhausted }
            let admission = episode.request(path, at: now)
            switch admission {
            case .now: _ = episode.begin(at: now)
            case .after: lifecycleAttemptPending = true      // begun by start() when the lifecycle runs it
            case .coalesced, .exhausted: break
            }
            return admission
        }
        AppController.note("bt_recovery=requested path=\(path.rawValue) admission=\(Self.word(admission))")
        // v1.10 (L1): a lifecycle start never lands inside the hands-off window.
        let held: TimeInterval = lock.withLock {
            let wait = ioGuard.remaining(at: now)
            if wait > 0 { ioGuard.deferred() }
            return wait
        }
        switch admission {
        case .now: return .proceed(after: held)
        case .after(let wait): return .proceed(after: max(wait, held))
        case .coalesced, .exhausted:
            // Refused: the episode's own queued attempt (or none) is the policy; the health clock
            // ends the dictation if nothing useful arrives. No restart outside the episode.
            return .skip
        }
    }

    private static func word(_ admission: BluetoothRecoveryEpisode.Admission) -> String {
        switch admission {
        case .now: return "now"
        case .after(let wait): return "after_\(Int((wait * 1000).rounded()))ms"
        case .coalesced: return "coalesced"
        case .exhausted: return "exhausted"
        }
    }

    private func registerConfigurationObserver() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        guard let observedEngine = engine else { return }
        let identity = lock.withLock { engineIdentity }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: observedEngine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // AVAudioEngine has already stopped itself; we only record and queue (L3).
            let now = ProcessInfo.processInfo.systemUptime
            let epoch: CaptureEpoch = self.lock.withLock {
                if self.engineIdentity === identity { self.episode.formatChanged(at: now) }
                return self.engineEpoch
            }
            self.onExecutor { [weak self] in
                self?.configurationChanged(identity: identity, epoch: epoch, queued: false, notifiedAt: now)
            }
        }
    }

    /// Runs on the executor. Bluetooth: admitted by the episode (one controlled recovery per
    /// window, after a stable format; a queued one is re-validated). Other inputs: at once.
    private func configurationChanged(identity: CaptureEpoch, epoch: CaptureEpoch, queued: Bool,
                                      notifiedAt: TimeInterval? = nil) {
        let current = { self.recording && self.lock.withLock {
            self.engineIdentity === identity &&
            self.captureRunning && self.engineEpoch === epoch
        } }
        let now = ProcessInfo.processInfo.systemUptime
        let bluetooth = lock.withLock { episode.bluetooth }
        if bluetooth {
            if queued {
                // Re-validated when it runs: same engine, same dictation, still needed.
                guard lock.withLock({ engineEpoch === epoch }) else { return }   // stale: never touch a newer episode
                let healthy = lock.withLock { feed.health.isFresh(.headset, at: now) }
                guard current(), !healthy else {
                    lock.withLock { episode.skip() }
                    AppController.note("bt_recovery=skipped path=configuration reason=\(healthy ? "healthy" : "obsolete")")
                    return
                }
                // v1.10 (L1): never inside the hands-off window; it runs when the window closes.
                let held: TimeInterval = lock.withLock {
                    let wait = ioGuard.remaining(at: now)
                    if wait > 0 { ioGuard.deferred() }
                    return wait
                }
                if held > 0 {
                    engineQueue.asyncAfter(deadline: .now() + held) { [weak self] in
                        self?.onExecutor { [weak self] in
                            self?.configurationChanged(identity: identity, epoch: epoch, queued: true)
                        }
                    }
                    return
                }
                switch lock.withLock({ episode.beginIfStable(at: now) }) {
                case .begun: break
                case .notPending: return
                case .wait(let more):
                    engineQueue.asyncAfter(deadline: .now() + more) { [weak self] in
                        self?.onExecutor { [weak self] in
                            self?.configurationChanged(identity: identity, epoch: epoch, queued: true)
                        }
                    }
                    return
                }
            } else {
                guard current() else { return }
                // v1.9 (L1): AVAudioEngine auto-stopped on the profile switch — re-attach IO now,
                // before coreaudiod tears the idle SCO route down (~250 ms after it connected).
                let running = (try? captureObjC { self.engine?.isRunning ?? false }) ?? false
                // v1.10 (L1): exactly ONE re-attach from the first notification, then hands off
                // for `HeadsetIOGuard.handsOff`; later notifications in the window do nothing.
                switch lock.withLock({ ioGuard.configurationChanged(at: now, engineRunning: running) }) {
                case .handsOff: return
                case .leaveRunning:
                    AppController.note("bt_recovery=hands_off path=configuration engine_running=1")
                    return
                case .reattach, .episode: break
                }
                let (admission, immediate): (BluetoothRecoveryEpisode.Admission, Bool) = lock.withLock {
                    let before = episode.immediateAttempts
                    let admission = episode.request(.configuration, at: now, engineStopped: !running)
                    return (admission, episode.immediateAttempts > before)
                }
                if immediate {
                    let afterMs = Int(((now - (notifiedAt ?? now)) * 1000).rounded())
                    AppController.note("bt_recovery=immediate path=configuration engine_running=0 after_ms=\(afterMs)")
                }
                switch admission {
                case .now: lock.withLock { _ = episode.begin(at: now) }
                case .after(let wait):
                    AppController.note("bt_recovery=queued path=configuration wait_ms=\(Int((wait * 1000).rounded()))")
                    engineQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
                        self?.onExecutor { [weak self] in
                            self?.configurationChanged(identity: identity, epoch: epoch, queued: true)
                        }
                    }
                    return
                case .coalesced: return
                case .exhausted:
                    AppController.note("bt_recovery=exhausted path=configuration")
                    return
                }
            }
        }
        guard current() else {
            if bluetooth { lock.withLock { if engineEpoch === epoch, episode.isRunning { episode.settled(.skipped) } } }
            return
        }
        stats.configChanges += 1
        var result: CaptureConfigurationRecovery.Result
        if bluetooth {
            // One admitted operation: a retap. No retap→rebuild escape inside the window; a failed
            // retap asks the episode for a full restart instead. Verification is armed first.
            verifyFrames(epoch: epoch, since: now, path: .configuration)
            lock.withLock { ioGuard.record(.retap) }
            do {
                try captureObjC {
                    try self.removeTap()
                    try self.installTapAndStart()
                }
                result = lock.withLock { engineEpoch === epoch } ? .retapped : .stale
            } catch {
                AppController.note("config_retap_error=\(error as NSError)")
                result = .failed
            }
        } else {
            // The observer identity was checked before entry. Our own rebuild
            // changes the engine/active flags, so only the epoch gates recovery.
            result = CaptureConfigurationRecovery.run(isCurrent: {
                self.lock.withLock { self.engineEpoch === epoch }
            }, retap: {
                self.lock.withLock { self.ioGuard.record(.retap) }
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
        }
        if result == .retapped || result == .rebuilt {
            let activated = self.lock.withLock {
                CaptureConfigurationRecovery.activate(epoch: epoch, current: self.engineEpoch) {
                    self.captureRunning = true
                }
            }
            if activated { self.recording = true }
            else { self.teardownEngine() }
            return
        }
        if bluetooth {
            lock.withLock {
                verifying = nil
                if engineEpoch === epoch, episode.isRunning { episode.settled(.failed) }
            }
            if result == .failed {
                // The headset engine stays as it is (stopped by AVAudioEngine); the built-in, if
                // healthy, keeps carrying; the episode decides the next attempt.
                requestHeadsetRestart(epoch: epoch, path: .configuration)
                return
            }
        }
        if result == .failed {
            // v1.7: a headset that cannot recover is not a failed dictation while the built-in carries it.
            let carried: (CaptureBridge.Event?, Bool) = lock.withLock {
                guard engineEpoch === epoch else { return (nil, false) }
                let out = feed.headsetFailed(at: ProcessInfo.processInfo.systemUptime)
                deliverLocked(out.frames)
                return (out.event, !out.deferred)
            }
            delivery.drain()
            if carried.0 == nil, !carried.1, lock.withLock({ engineEpoch === epoch }) {
                AppController.note("headset_engine_failed=1 builtin_carries=pending_fresh")
                return
            }
            if let event = carried.0 {
                AppController.note("headset_engine_failed=1 builtin_carries=\(event == .switchback ? "switchback" : "fallback")")
                Self.noteCarried(event, reason: "headset_engine_failed")
                return
            }
            if carried.1 { reportEngineFailure(epoch: epoch) }
        }
    }

    /// The built-in carries the rest of the dictation after a headset failure (bt-proof.sh reads this).
    private static func noteCarried(_ event: CaptureBridge.Event, reason: String) {
        AppController.note(event == .switchback ? "bridge_switchback=1 reason=\(reason)"
                                                 : "bridge_src=builtin_fallback reason=\(reason)")
    }

    private func reportEngineFailure(epoch: CaptureEpoch) {
        let failure: CaptureFailure = lock.withLock {
            CaptureFailure(reason: .engine, durationSeconds: captureBoundary.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0,
                           bytes: 44 + samples.count * 2, framesKept: samples.count,
                           sources: feed.health.summary(at: ProcessInfo.processInfo.systemUptime))
        }
        let callback = onCaptureFailure
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lock.withLock({ self.engineEpoch === epoch }) else { return }
            callback?(failure)
        }
    }

    /// The parent engine on the MicStartChain built-in path: read back its device once (H3 diagnostic).
    @discardableResult private func checkBuiltinPin() -> BuiltinPin.Check? {
        guard let unit = engine?.inputNode.audioUnit, let expected = try? AudioDevices.builtInInput() else { return nil }
        let check = BuiltinPin.enforce(expected: expected, read: {
            try AudioDevices.currentDevice(of: self.requireEngine().inputNode.audioUnit ?? unit)
        }, write: { _ in
            self.lock.withLock { self.ioGuard.record(.retap); self.ioGuard.record(.stop) }
            try self.removeTap()
            try captureObjC { self.engine?.stop() }
            try AudioDevices.selectBuiltIn(on: self.requireEngine().inputNode)
            try self.installTapAndStart()
        })
        AppController.note(check.note)
        return check
    }

    /// L3: every headset restart request goes through the episode.
    private func requestHeadsetRestart(epoch: CaptureEpoch, path: RecoveryPath) {
        let now = ProcessInfo.processInfo.systemUptime
        let admission: BluetoothRecoveryEpisode.Admission = lock.withLock {
            guard engineEpoch === epoch else { return .exhausted }
            return episode.request(path, at: now)
        }
        switch admission {
        case .now: onExecutor { [weak self] in self?.restartHeadset(epoch: epoch, path: path, queued: false) }
        case .after(let wait):
            AppController.note("bt_recovery=queued path=\(path.rawValue) wait_ms=\(Int((wait * 1000).rounded()))")
            engineQueue.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.onExecutor { [weak self] in self?.restartHeadset(epoch: epoch, path: path, queued: true) }
            }
        case .coalesced: break
        case .exhausted: AppController.note("bt_recovery=exhausted path=\(path.rawValue)")
        }
    }

    /// H2 (admitted by the episode): one clean restart so coreaudiod re-requests the dropped eSCO
    /// link. Our own units on the headset are confirmed stopped before the busy check (the
    /// built-in unit is on its own physical device and never holds the headset).
    private func restartHeadset(epoch: CaptureEpoch, path: RecoveryPath, queued: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        // Validity = this dictation is live (its epoch, its recording boundary), not whether the
        // headset engine happens to be running: a stopped headset is the reason to restart it.
        let (current, healthy, builtinCarries, device) = lock.withLock {
            (engineEpoch === epoch && feed.bridge.isRecording && feed.bridge.state != .off,
             feed.health.isFresh(.headset, at: now), feed.health.status(.builtin, at: now) == .healthy, headsetDevice)
        }
        guard lock.withLock({ engineEpoch === epoch }) else { return }      // stale: never touch a newer episode
        // restart_request_becomes_obsolete: re-validated when it runs, settled as skipped.
        guard current, !(queued && healthy) else {
            lock.withLock { episode.skip() }
            AppController.note("bt_recovery=skipped path=\(path.rawValue) reason=\(current ? "healthy" : "obsolete")")
            return
        }
        // v1.10 (L1): a restart (stop + rebuild + start) never runs inside the hands-off window.
        let held: TimeInterval = lock.withLock {
            let wait = ioGuard.remaining(at: now)
            if wait > 0 { ioGuard.deferred() }
            return wait
        }
        if held > 0 {
            engineQueue.asyncAfter(deadline: .now() + held) { [weak self] in
                self?.onExecutor { [weak self] in self?.restartHeadset(epoch: epoch, path: path, queued: true) }
            }
            return
        }
        switch lock.withLock({ episode.beginIfStable(at: now) }) {
        case .begun: break
        case .notPending: return
        case .wait(let more):
            engineQueue.asyncAfter(deadline: .now() + more) { [weak self] in
                self?.onExecutor { [weak self] in self?.restartHeadset(epoch: epoch, path: path, queued: true) }
            }
            return
        }
        lock.withLock { restarting = true; restartEpoch = epoch }
        defer { lock.withLock { restarting = false } }
        // Same shape as a cold start: a fresh engine, never the stopped one (its input
        // format reads 0 Hz while the headset is back on A2DP).
        let outcome = HeadsetRestart.perform(stop: {
            self.teardownEngine()
            return self.lock.withLock { self.engine == nil }
        }, isRunningSomewhere: {
            device.flatMap { AudioDevices.isRunningSomewhere($0) }
        }, sleep: { Thread.sleep(forTimeInterval: $0) }, start: {
            guard self.lock.withLock({ self.engineEpoch === epoch }) else { throw CancellationError() }
            self.verifyFrames(epoch: epoch, since: ProcessInfo.processInfo.systemUptime, path: path)    // armed before the start
            try self.rebuild()
            try self.installTapAndStart()
            let activated = self.lock.withLock {
                CaptureConfigurationRecovery.activate(epoch: epoch, current: self.engineEpoch) {
                    self.captureRunning = true
                }
            }
            guard activated else { self.teardownEngine(); throw CancellationError() }
            self.recording = true
        }, startWhenBusy: !builtinCarries, note: { error in
            self.teardownEngine()
            AppController.note("headset_restart_error=\(error as NSError)")
        })
        let carried: (nothing: Bool, event: CaptureBridge.Event?) = lock.withLock {
            guard engineEpoch === epoch else { return (false, nil) }
            feed.headsetRestarted(started: outcome.started)
            if !outcome.started { verifying = nil }
            if outcome.externalBusy { episode.settled(.externalBusy) }
            else if !outcome.started { episode.settled(.failed) }
            guard !outcome.started else { return (false, nil) }
            let out = feed.headsetFailed(at: ProcessInfo.processInfo.systemUptime)
            deliverLocked(out.frames)
            return (out.event == nil && !out.deferred, out.event)
        }
        delivery.drain()
        AppController.note("headset_restart=1 path=\(path.rawValue) idle=\(outcome.deviceIdle ? 1 : 0) waited_ms=\(outcome.waitedMs) started=\(outcome.started ? 1 : 0)")
        if outcome.externalBusy {
            AppController.note("bt_external_busy=1 device=\(device.map(String.init) ?? "?") builtin_carries=\(builtinCarries ? 1 : 0)")
            // At most one more attempt this dictation, admitted like any other (no spin).
            if !outcome.started { requestHeadsetRestart(epoch: epoch, path: .restart) }
        }
        // Notes reach the host's sink: never under `lock`.
        if let event = carried.event { Self.noteCarried(event, reason: "headset_restart_failed") }
        if carried.nothing { reportEngineFailure(epoch: epoch) }
    }

    /// L3: a restart succeeded only if headset frames arrive within 1.0 s (not when start() returned).
    /// Judged on the health queue (never behind a busy executor): the first headset frame after
    /// `since` must arrive by `since + 1 s`; a later frame is not this attempt's success.
    private func verifyFrames(epoch: CaptureEpoch, since: TimeInterval, path: RecoveryPath) {
        let token = CaptureEpoch()
        lock.withLock { verifying = (token, since, nil, nil) }
        healthQueue.asyncAfter(deadline: .now() + BluetoothRecoveryEpisode.successWithin) { [weak self] in
            guard let self else { return }
            let result: BluetoothRecoveryEpisode.Outcome? = self.lock.withLock {
                guard let check = self.verifying, check.token === token else { return nil }
                self.verifying = nil
                guard self.engineEpoch === epoch, self.episode.isRunning else { return nil }
                let outcome = BluetoothRecoveryEpisode.verdict(since: since, firstFrame: check.firstFrame,
                                                               firstSignal: check.firstSignal)
                self.episode.settled(outcome)
                return outcome
            }
            if let result { AppController.note("bt_recovery=settled path=\(path.rawValue) result=\(result.rawValue)") }
        }
    }

    private func requireEngine() throws -> AVAudioEngine {
        guard let engine else { throw RecorderError.noInput }
        return engine
    }

    private func installTapAndStart() throws {
        // v1.10 (L1): on Bluetooth after the first configuration notification, no rebuild and no
        // client-format alignment: the tap takes the node's own format and `consume` converts it.
        if lock.withLock({ ioGuard.convertsInTap }) { return try installConvertingTapAndStart() }
        try captureObjC {
            let plan = try TapFormatPlan.run(device: selectedDevice, formats: {
                let input = try requireEngine().inputNode
                let hardware = input.inputFormat(forBus: 0), output = input.outputFormat(forBus: 0)
                return (TapFormatPlan.Format(sampleRate: hardware.sampleRate, channels: hardware.channelCount),
                        TapFormatPlan.Format(sampleRate: output.sampleRate, channels: output.channelCount))
            }, align: {
                lock.withLock { ioGuard.record(.align) }
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
            lock.withLock { ioGuard.record(.start) }
            try requireEngine().start()
        }
    }

    /// The hands-off re-attach: tap in the input node's current output format (nil = whatever the
    /// bus delivers; never a format-mismatch exception), converted to 24 kHz per buffer in `consume`.
    private func installConvertingTapAndStart() throws {
        try captureObjC {
            let input = try requireEngine().inputNode
            let hardware = input.inputFormat(forBus: 0), output = input.outputFormat(forBus: 0)
            if hardware.sampleRate != output.sampleRate || hardware.channelCount != output.channelCount {
                AppController.note("bt_reattach_converted=1 hw=\(Int(hardware.sampleRate))Hz/\(hardware.channelCount)ch out=\(Int(output.sampleRate))Hz/\(output.channelCount)ch")
            }
            lock.withLock { converter = nil }      // built from the first buffer's own format
            let token = CaptureEpoch()
            lock.withLock { tapEpoch = token }
            tapInstalled = true
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
                self?.consume(buffer, time: time, epoch: token)
            }
            try requireEngine().prepare()
            lock.withLock { ioGuard.record(.start) }
            try requireEngine().start()
        }
    }

    private func removeTap() throws {
        guard tapInstalled else { return }
        defer { tapInstalled = false; lock.withLock { tapEpoch = CaptureEpoch() } }
        try captureObjC { try requireEngine().inputNode.removeTap(onBus: 0) }
    }

    /// Continue cleanup after any individual exception, including a partial tap install.
    /// `counted`: the caller already recorded this stop (`stop()` counts its own teardown).
    private func teardownEngine(counted: Bool = false) {
        recording = false
        lock.withLock { if engine != nil, !counted { ioGuard.record(.stop) } }
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
    /// v1.8: the health clock starts here.
    public func resetCapture() {
        let (kept, epoch): (Int, CaptureEpoch) = lock.withLock {
            let boundary = ProcessInfo.processInfo.systemUptime
            captureBoundary = boundary
            let preRoll = feed.recordingStarted(at: boundary)
            samples.removeAll(keepingCapacity: true)
            samples.append(contentsOf: preRoll)
            pendingPCM = WAVEncoder.pcm16(from: preRoll)
            levelTimer?.cancel()
            levelTimer = nil
            meter.clearBatch()
            return (preRoll.count, engineEpoch)
        }
        if kept > 0 { AppController.note("tap2_to_first_kept_buffer_ms=0 kept_src=ring preroll_frames=\(kept)") }
        startHealthClock(epoch: epoch)
    }

    private func startHealthClock(epoch: CaptureEpoch) {
        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now() + CaptureHealth.tickInterval, repeating: CaptureHealth.tickInterval)
        timer.setEventHandler { [weak self] in self?.healthTick(epoch: epoch) }
        lock.withLock {
            healthTimer?.cancel()
            healthTimer = timer
        }
        timer.resume()
    }

    /// L2: one 100 ms evaluation, independent of any tap callback.
    private func healthTick(epoch: CaptureEpoch) {
        let unit: BuiltinCapture? = lock.withLock { builtinActive && engineEpoch === epoch ? builtin : nil }
        // Device read-back every tick (L1): a mismatch marks the built-in dead, never ignored.
        let check = unit?.deviceCheck()
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard engineEpoch === epoch, feed.bridge.isRecording else { lock.unlock(); return }
        var driftNote: String?
        if builtinActive, let check, check != .ok, !builtinDriftNoted {
            builtinDriftNoted = true
            feed.deviceProblem(.builtin, .drift)
            driftNote = check.note
        }
        let out = feed.tick(at: now)
        deliverLocked(out.frames)
        var deadUnit: (BuiltinCapture, DispatchQueue)?
        if out.stopBuiltin, builtinActive { builtinActive = false; deadUnit = (builtin, builtinQueue) }
        if out.failure != nil { healthTimer?.cancel(); healthTimer = nil }
        let callback = onCaptureFailure
        lock.unlock()
        delivery.drain()
        if let driftNote { AppController.note(driftNote) }
        out.notes.forEach { AppController.note($0) }
        if let (unit, queue) = deadUnit { stopBuiltinUnit(unit, queue: queue, epoch: epoch) }
        if let failure = out.failure {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ self.engineEpoch === epoch }) else { return }
                callback?(failure)
            }
        }
    }

    @discardableResult public func stop() -> [Float] {
        // Invalidates a queued/in-flight start without waiting for AVAudioEngine.
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let stoppedEpoch = engineEpoch
        engineEpoch = CaptureEpoch()
        verifying = nil
        lifecycleAttemptPending = false
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
            stats.captureIntervals = feed.evidence.intervalsNote
            stats.speechSections = feed.evidence.finalSpeechSections
            stats.recordingMs = captureBoundary.map { max(0, Int(((now - $0) * 1000).rounded())) } ?? 0
            stats.builtinFramesAfterFallback = feed.bridge.builtinFramesAfterFallback
            stats.builtinBackend = feed.bridge.bridgeSource == "none" ? nil : builtin.backend
            // v1.10 (L1): the teardown queued below is this dictation's last stop.
            if engine != nil { ioGuard.record(.stop) }
            stats.ioOps = ioGuard.note
            stats.ioHeld = ioGuard.heldNote
            stats.carrier = feed.bridge.carrierNote(endMs: stats.recordingMs)
            stats.headsetCarriedMs = feed.bridge.headsetCarriedMs(endMs: stats.recordingMs)
            stats.captureIntervalsTruncated = feed.evidence.truncated
            stats.kind = captureKind
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
        healthTimer?.cancel()
        healthTimer = nil
        meter.clearBatch()
        let stopUnit: (BuiltinCapture, DispatchQueue)? = builtinActive ? (builtin, builtinQueue) : nil
        builtinActive = false
        var abandonedMs: Int?
        // Its queued teardown would wait forever behind a wedged call (D-b).
        if let busy = builtinWedgedMsLocked() {
            abandonedMs = busy
            builtin = makeBuiltin()
            builtinQueue = DispatchQueue(label: "dictate.capture.builtin")
            builtinWatch = CaptureExecutorWatch()
        }
        lock.unlock()
        if let abandonedMs { AppController.note("bridge_abandoned=1 busy_ms=\(abandonedMs)") }
        if let restartResult { AppController.note("headset_restart=1 result=\(restartResult)") }
        if !remainder.isEmpty, let callback { delivery.enqueue(remainder, to: callback) }
        delivery.drain()
        if let (unit, queue) = stopUnit, abandonedMs == nil { stopBuiltinUnit(unit, queue: queue, epoch: stoppedEpoch) }
        onExecutor { [self] in teardownEngine(counted: live) }
        return captured
    }

    private func consume(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, epoch token: CaptureEpoch) {
        // The converter must match the buffers actually arriving: a format
        // change under a live tap otherwise yields garbled (resampled-wrong) audio.
        let epoch = lock.withLock { engineEpoch }
        let converter: AVAudioConverter? = lock.withLock {
            guard captureRunning, tapEpoch === token else { return nil }
            if stats.firstBufferMs == nil {
                stats.firstBufferMs = elapsedMs()
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
        if let error { AppController.note("headset_convert_error=\(error.domain):\(error.code)") }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        // AVAudioTime and the AUHAL timestamps share the host-clock domain.
        let hostStart = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) :
            ProcessInfo.processInfo.systemUptime - Double(chunk.count) / Self.sampleRate
        acceptConverted(chunk, at: hostStart, source: .headset, epoch: epoch, tap: token)
    }

    /// Arbitration, accumulation and meter updates share this lock; PCM is enqueued in order
    /// under it and delivered after it (a switch cannot overtake a buffer's delivery).
    private func acceptConverted(_ converted: [Float], at time: TimeInterval,
                                 source: CaptureBridge.Source, epoch: CaptureEpoch,
                                 tap: CaptureEpoch? = nil) {
        lock.lock()
        guard engineEpoch === epoch, tap == nil || (tapEpoch === tap && captureRunning) else { lock.unlock(); return }
        let arrival = ProcessInfo.processInfo.systemUptime
        if source == .headset, verifying != nil, arrival > (verifying?.since ?? .infinity) {
            if verifying?.firstFrame == nil { verifying?.firstFrame = arrival }
            // v1.9: digital zeros (an idle SCO route) are not a recovered headset.
            if verifying?.firstSignal == nil,
               converted.contains(where: { abs($0) >= CaptureBridge.silencePeak }) { verifying?.firstSignal = arrival }
        }
        let decision = feed.accept(converted, source: source, at: time, arrivedAt: arrival, epoch: epoch)
        deliverLocked(decision.frames)
        let bridgeMs = feed.bridge.bridgeMs, builtinFrames = feed.bridge.builtinFrames
        let firstKeptMs = decision.firstKept ? feed.bridge.firstKeptMs : nil
        // v1.7: the built-in keeps running after the headset takes over (it is the
        // switchback source) and is released when the dictation stops.
        lock.unlock()
        delivery.drain()
        if decision.restartHeadset { requestHeadsetRestart(epoch: epoch, path: .restart) }
        switch decision.event {
        case .fallback?: AppController.note("bridge_src=builtin_fallback reason=headset_digital_silence")
        case .switchback?: AppController.note("bridge_switchback=1")
        case .recovered?: AppController.note("bridge_switch=headset reason=recovered")
        case nil: break
        }
        if let fresh = decision.fallbackFresh {
            AppController.note("fallback_check builtin_fresh_at_fallback=\(fresh ? 1 : 0) builtin_age_ms=\(decision.builtinAgeMs.map(String.init) ?? "none")\(decision.fallbackRefused ? " refused=1" : "")")
        }
        if decision.headsetSignalStart { AppController.note("headset_signal_start=1") }
        if let firstKeptMs {
            AppController.note("tap2_to_first_kept_buffer_ms=\(firstKeptMs) kept_src=\(source == .builtin ? "builtin" : "headset")")
        }
        if decision.releaseBuiltin {
            if let bridgeMs { AppController.note("bridge_ms=\(bridgeMs) bridge_src=builtin builtin_frames=\(builtinFrames)") }
        }
    }

    /// Accumulation, ordered PCM enqueue and meter updates for frames the feed kept. Caller holds `lock`.
    private func deliverLocked(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
        // Accumulate even before the transcriber attaches; nothing after the
        // recording boundary is discarded during asynchronous hardware startup.
        pendingPCM.append(contentsOf: WAVEncoder.pcm16(from: chunk))
        if let callback = pcmCallback {
            while pendingPCM.count >= Self.chunkSamples {
                let pcm = Array(pendingPCM.prefix(Self.chunkSamples))
                pendingPCM.removeFirst(Self.chunkSamples)
                delivery.enqueue(pcm, to: callback)
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
