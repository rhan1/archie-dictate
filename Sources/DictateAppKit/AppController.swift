import AppKit
import DictateCore

/// Wires the hotkey, recorder, pill, transcription and paste together around
/// the pure DictationStateMachine.
public final class AppController {
    private var machine = DictationStateMachine()
    private let hotkeys = HotkeyMonitor()
    private let recorder: EngineRecorder
    private let dependencies: EngineDependencies?
    let pill: EnginePanel
    private var statusItem: StatusItemController?
    private let inserter: TextInserter
    private let keyStore: KeyStore
    private let paths: AppPaths
    var engineOnState: ((DictateAppKit.DictationState) -> Void)?
    var engineOnTranscript: ((String, DictationTimeline) -> Void)?
    let quotaStore: GroqQuotaStore
    private let rateLimitRelay: EngineRateLimitRelay
    var engineOnGroqRateLimit: ((GroqRateLimit) -> Void)? {
        get { MainActor.assumeIsolated { rateLimitRelay.callback } }
        set { MainActor.assumeIsolated { rateLimitRelay.callback = newValue } }
    }
    var engineMode: DictationEngine.Mode
    var forceFallback: FallbackOverride?
    var engineSurface: Surface {
        get { pill.surface }
        set { pill.surface = newValue }
    }
    private var sessionPolicy = EnginePolicy()
    private var engineConfigured = false
    private lazy var facade = MainActor.assumeIsolated { DictationEngine(controller: self) }
    private var prompt: String { Vocabulary.buildPrompt(fileURL: paths.vocabularyURL) }
    /// Local cleanup is the fallback when Groq fails.
    private var localCleaner: TranscriptCleaner
    /// Cleanup default (G7 round 2): Groq qwen3.8-27b, 10/10 quality, p50 367 ms.
    private var groqCleaner: TranscriptCleaner
    /// Batch Groq STT is used only for explicitly enabled shadow QA.
    private let groqSTT: TranscriptionClient
    private var apple: EngineAppleSession?
    public static let defaultSTTEngine = "groq-chunked"
    private let sttEngine = ProcessInfo.processInfo.environment["DICTATE_STT"] == "apple"
        ? "apple" : AppController.defaultSTTEngine
    private var chunkedEnabled: Bool { (sttEngine == "groq-chunked" || sessionPolicy.mode == .captureOnly) && sessionPolicy.usesGroqSTT }
    private var chunked: EngineChunkSession?
    private var incrementalCleaner: IncrementalCleaner?
    /// Bluetooth warm-up: engine pre-started on the first ⌥ tap, WARMING pill
    /// until the first buffer (G8).
    private lazy var capture = CaptureLifecycle(engine: recorder, scheduler: captureScheduler)
    /// Media keeps playing, muted while recording. Pausing is the fallback
    /// for devices without a settable output mute flag.
    private let muter: OutputMuter
    private let media = MediaPauser(control: SystemMedia())
    private var muteWatchdog: DispatchWorkItem?
    private var signalSource: DispatchSourceSignal?
    private var mediaLog: [String] = []
    /// L4 lever: bypasses the network with a fixed transcript.
    private let fakeTranscript = ProcessInfo.processInfo.environment["DICTATE_FAKE_TRANSCRIPT"]
    /// Opt-in QA comparison; the detached Groq request never delays paste.
    private let shadowEnabled = ProcessInfo.processInfo.environment["DICTATE_SHADOW"] == "1"
    /// QA lever: notes pill show/hide with the frontmost app (G4) to stderr.
    private let trace = ProcessInfo.processInfo.environment["DICTATE_TRACE"] == "1"

    private var recordingStarted: Date?
    private var btStart = "none"
    private var btEndNotePending = false
    private var foreignHFP = ForeignHFPLatch()
    private var foreignHFPPoll: Timer?
    private var recordingTarget: InsertionTarget?
    private var lastDictation: String?
    private var lastDictationTimer: Timer?
    private var generation = CaptureEpoch()
    private let captureScheduler = CaptureDispatchScheduler()
    private var micStarting = false
    private var micAvailable = false
    private var pillOutcome: PillOutcome?
    private var outcomeText: String?
    private var outcomeTimer: Timer?
    private var recoveryTap: DispatchWorkItem?

    public convenience init() {
        self.init(keyStore: KeyStore(), paths: AppPaths(), surface: .pill, mode: .dictate)
    }

    init(keyStore: KeyStore, paths: AppPaths, surface: Surface, mode: DictationEngine.Mode,
         dependencies: EngineDependencies? = nil, quotaFileURL: URL? = nil) {
        self.dependencies = dependencies
        // The default location shares GroqQuota.current; a host's relocated file gets its own store.
        let quotaFile = quotaFileURL ?? GroqQuotaStore.defaultFileURL(for: paths)
        quotaStore = quotaFile == GroqQuotaStore.shared.fileURL ? .shared : GroqQuotaStore(fileURL: quotaFile)
        rateLimitRelay = EngineRateLimitRelay(store: quotaStore)
        recorder = dependencies?.recorder ?? AudioRecorder()
        inserter = dependencies?.inserter ?? TextInserter()
        self.keyStore = keyStore
        self.paths = paths
        pill = EnginePanel(surface: surface, factory: dependencies?.panelFactory ?? { PillPanel() })
        engineMode = mode
        muter = OutputMuter(device: SystemOutputMute(), stateFile: paths.mutedStateURL)
        let prompt = Vocabulary.buildPrompt(fileURL: paths.vocabularyURL)
        let keys = keyStore
        let groqKey: @Sendable () throws -> String = {
            guard let key = keys.key(for: "groq-api") else { throw TranscriptionError.missingKey }
            return key
        }
        var local = TranscriptCleaner(transport: dependencies?.localCleanupTransport ?? URLSessionTransport(timeout: 2), endpoint: TranscriptCleaner.ollamaEndpoint,
                                         model: TranscriptCleaner.localModel, vocabulary: prompt, apiKey: { "ollama" })
        local.reloadVocabularyFromHints = true
        localCleaner = local
        var groq = TranscriptCleaner(transport: dependencies?.groqCleanupTransport ?? URLSessionTransport(timeout: 1.5), endpoint: TranscriptCleaner.groqEndpoint,
                                     model: TranscriptCleaner.defaultModel, vocabulary: prompt, apiKey: groqKey)
        groq.reasoningEffort = "none"
        groq.reloadVocabularyFromHints = true
        groqCleaner = groq
        let shadowTransport = EngineGroqTransport(transport: dependencies?.sttTransport ?? URLSessionTransport(timeout: 30),
            observer: { [rateLimitRelay] in rateLimitRelay.observe($0) })
        var whisper = TranscriptionClient(transport: shadowTransport, apiKey: groqKey)
        whisper.endpointURL = TranscriptionClient.groqEndpoint
        whisper.modelName = "whisper-large-v3-turbo"
        groqSTT = whisper
        groqCleaner.onGroqRateLimit = { [rateLimitRelay] in rateLimitRelay.observe($0) }
        // Default paths keep today's reload behavior; hosts can isolate vocabulary.
        if paths.vocabularyURL != AppPaths().vocabularyURL {
            localCleaner.reloadVocabularyFromHints = false
            groqCleaner.reloadVocabularyFromHints = false
            let hints = VocabHints.promptSentence(VocabHints.load(fileURL: paths.vocabularyURL))
            localCleaner.hintsSentence = hints
            groqCleaner.hintsSentence = hints
        }
    }

    public func start() {
        _ = facade // Standalone uses the same public controls as an embedding host.
        statusItem = StatusItemController()
        configureEngine()
        do {
            let copied = try AppPaths.migrate()
            AppController.note("migrated=\(copied.isEmpty ? "none" : copied.joined(separator: ","))")
        } catch {
            AppController.note("migration_error=\(error.localizedDescription)")
        }
        keyStore.prefetch(services: ["groq-api"])
        logKeyStates()
        hotkeys.onSignal = { [weak self] signal in MainActor.assumeIsolated { self?.facade.handle(signal) } }
        hotkeys.onEscape = { [weak self] in MainActor.assumeIsolated { self?.facade.escape() } }
        statusItem?.onToggle = { [weak self] in MainActor.assumeIsolated { self?.facade.handle(.doubleTap) } }
        statusItem?.onPasteLastDictation = { [weak self] in
            guard let self, let text = self.lastDictation else { return }
            self.inserter.insert(text)
        }

        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let tapOK = hotkeys.start()
        AppController.note("started pid=\(getpid()) accessibility=\(trusted) eventTap=\(tapOK) promptChars=\(prompt.count) fake=\(fakeTranscript != nil) bt_profile=\(BluetoothProfile.sample())")
        // Property reads only; never opens a device.
        foreignHFPPoll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForeignHFP(BluetoothProfile.sample()) }
        }
        if !tapOK {
            // Without the grant there is no tap; retry quietly until the user approves.
            retryTapUntilGranted()
        }
        if !trusted { watchAccessibilityGrant() }
        if fakeTranscript == nil {
            warmLocalModel()
            Task { await AppleTranscriber.ensureAssets() }
        }
        // Verified settle events can occur after the dictation timeline is emitted.
        muter.onEvent = { event in AppController.note(event.rawValue) }
        // A run that crashed while muted is undone at launch.
        if let event = muter.recoverIfNeeded() { AppController.note("media=\(event.rawValue) (at launch)") }
        installTerminationRestore()
        AudioRecorder.requestMicrophoneAccess { [weak self] granted in
            self?.micAvailable = granted
            AppController.note("microphone=\(granted)")
        }
    }

    func configureEngine() {
        guard !engineConfigured else { return }
        engineConfigured = true
        configureCapture()
        pill.onCancel = { [weak self] in self?.cancel() }
        pill.onFinish = { [weak self] in self?.finishButton() }
        pill.onMode = { [weak self] mode in
            switch mode {
            case .warming: self?.engineOnState?(.warming)
            case .recording: self?.engineOnState?(.recording(level: 0))
            case .transcribing: self?.engineOnState?(.transcribing)
            case .hidden: self?.engineOnState?(.idle)
            case .error: break // Outcome supplies the exact PillOutcome word/preview.
            }
        }
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            self.pill.push(level: level)
            if self.machine.state == .recording { self.engineOnState?(.recording(level: max(0, min(1, level)))) }
        }
    }

    func engineStart() {
        configureEngine()
        guard machine.state == .idle else { return }
        if forceFallback != .quota { keyStore.prefetch(services: ["groq-api"]) }
        let requestAccess = dependencies?.requestMicrophoneAccess ?? AudioRecorder.requestMicrophoneAccess
        requestAccess { [weak self] in self?.micAvailable = $0 }
        doubleTap()
    }
    func engineFinish() { finishButton() }
    func engineRecoverStaleMute() -> String? {
        guard let event = muter.recoverIfNeeded() else { return nil }
        AppController.note("media=\(event.rawValue) (host launch)")
        return event.rawValue
    }
    func engineCancel() { cancel() }
    func engineEscape() { escape() }
    func engineHotkey(_ signal: TapSignal) { hotkey(signal) }
    func enginePasteHeld() { outcomeEvent(.recoverTap) }
    func engineCopyHeld() {
        guard let text = outcomeText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘V is only delivered once Accessibility is granted; note the moment it is.
    private func watchAccessibilityGrant() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if AXIsProcessTrusted() {
                AppController.note("accessibility=true after grant")
            } else {
                self?.watchAccessibilityGrant()
            }
        }
    }

    private func retryTapUntilGranted() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if self.hotkeys.start() {
                AppController.note("eventTap=true after grant")
            } else {
                self.retryTapUntilGranted()
            }
        }
    }

    // MARK: - Inputs

    private func doubleTap() {
        clearOutcome()
        perform(machine.doubleTap())
    }

    /// ⌥⌥ starts, one clean ⌥ tap finishes (A2). A clean tap while idle may be
    /// the first half of a double-tap: prewarm capture and cleanup.
    private func hotkey(_ signal: TapSignal) {
        if pillOutcome?.isRecoverable == true, machine.state == .idle {
            switch signal {
            case .tap:
                recoveryTap?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.outcomeEvent(.singleOptionTap) }
                recoveryTap = work
                // A second press can start at the edge of the window and last maxHold.
                DispatchQueue.main.asyncAfter(deadline: .now() + DoubleTapDetector.defaultWindow + DoubleTapDetector.defaultMaxHold,
                                              execute: work)
            case .doubleTap: doubleTap()
            case .none: break
            }
            return
        }
        if signal == .doubleTap { clearOutcome() }
        if signal == .tap, machine.state == .idle {
            clearOutcome()
            if fakeTranscript == nil, engineMode == .dictate {
                if forceFallback == nil { Task { [groqCleaner] in await groqCleaner.warmUp() } }
                warmLocalModel()
            }
            prewarmEngine()
        }
        perform(machine.handle(signal))
    }

    private func warmLocalModel() {
        Task { [localCleaner] in await localCleaner.warmUp() }
    }

    private func logKeyStates() {
        let state = keyStore.missing(for: "groq-api")?.rawValue ?? "ok"
        Self.note("keys=groq:\(state)")
    }

    func showOutcome(_ kind: PillOutcome.Kind, text: String? = nil) {
        clearOutcome()
        outcomeText = text
        pillOutcome = PillOutcome(kind, hasText: text?.isEmpty == false)
        renderOutcome()
        engineOnState?(.outcome(kind, text: text))
        guard pillOutcome?.isVisible == true else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.outcomeEvent(.tick(elapsed: ProcessInfo.processInfo.systemUptime - start))
        }
        outcomeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func outcomeEvent(_ event: PillOutcome.Event) {
        guard var outcome = pillOutcome else { return }
        let output = outcome.handle(event)
        pillOutcome = outcome
        let text = outcomeText
        if output.label == nil { clearOutcome() }
        else { renderOutcome() }
        if output.pasteHeldText, let text { inserter.insert(text); engineOnState?(.pasted) }
    }

    private func renderOutcome() {
        guard let outcome = pillOutcome, let label = outcome.label else { pill.hide(); return }
        pill.show(.error, held: outcome.showsPasteAffordance, status: label)
    }

    private func clearOutcome() {
        recoveryTap?.cancel()
        recoveryTap = nil
        outcomeTimer?.invalidate()
        outcomeTimer = nil
        pillOutcome = nil
        outcomeText = nil
        pill.hide()
    }

    /// First ⌥ tap: start the engine now so a Bluetooth headset's profile
    /// switch overlaps the second tap. Stopped silently if no ⌥⌥ follows.
    private func prewarmEngine() {
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.capture.firstTapAsync(start: { try await self.recorder.startAsync(device: $0) },
                isCancelled: { self.generation !== token || self.machine.state != .idle })
        }
    }

    private func checkForeignHFP(_ profile: String) {
        if foreignHFP.observe(profile: profile, engineAllocated: recorder.isAllocated, idle: machine.state == .idle) {
            Self.note("bt_hfp_foreign=1 bt_profile=\(profile) engine_allocated=false")
        }
    }

    private func configureCapture() {
        capture.note = { AppController.note($0) }
        capture.dropHooks = { [weak self] in
            guard let self else { return }
            self.recorder.onPCMChunk = nil
            guard self.btEndNotePending else { return }
            self.btEndNotePending = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                let profile = BluetoothProfile.sample()
                Self.note("bt_after3s=\(profile) bt_profile=\(profile) engine_allocated=\(self.recorder.isAllocated)")
                self.checkForeignHFP(profile)
            }
        }
        capture.onEpochChanged = { [weak self] token in
            self?.recorder.onFirstBuffer = { [weak self] in
                self?.capture.bufferArrived(at: ProcessInfo.processInfo.systemUptime, epoch: token)
            }
            self?.recorder.onCaptureFailure = { [weak self] in self?.capture.engineFailed(epoch: token) }
        }
        // Also bind the initial prewarm epoch before any recording has begun.
        capture.onEpochChanged?(capture.epoch)
        capture.onFailure = { [weak self] in
            guard let self, self.fakeTranscript == nil else { return }
            self.fail(reason: "mic_\(self.micAvailable ? "start" : "denied")", duration: 0, bytes: 0, latencyMs: 0)
        }
        capture.onMaxDuration = { [weak self] in
            guard let self else { return }
            self.perform(self.machine.maxDurationReached())
        }
        capture.onEffect = { [weak self] effect in
            guard let self else { return }
            switch effect {
            case .showWarming: self.pill.show(.warming)
            case .showLive:
                if self.machine.state == .recording {
                    self.pill.show(.recording)
                    self.pauseMedia()
                }
            default: break
            }
        }
    }

    /// Recording is live: mute the output (media keeps playing). Only a device
    /// with no mute flag falls back to pausing media.
    private func pauseMedia() {
        guard fakeTranscript == nil, dependencies?.manageMedia != false else { return }
        if let event = muter.recoverIfNeeded() { mediaLog.append(event.rawValue) }
        let event = muter.mute()
        switch event {
        case .muted:
            mediaLog.append("muted")
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, let restored = self.muter.restore() else { return }
                AppController.note("mute watchdog fired: \(restored.rawValue)")
            }
            muteWatchdog?.cancel()
            muteWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 330, execute: watchdog)   // 5.5 min
        case .unsupported:
            let paused = media.pauseIfPlaying()
            mediaLog.append(paused == .paused ? "paused:no_mute" : paused.rawValue)
            if paused == .paused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, let event = self.media.verifyAfterPause() else { return }
                    self.mediaLog.append(event.rawValue)
                }
            }
        default:
            mediaLog.append(event.rawValue)
        }
    }

    /// Every end path (paste, cancel, error, silence, cap) restores the mute
    /// flag on the device we muted, and resumes anything the fallback paused.
    private func resumeMedia() -> String {
        guard dependencies?.manageMedia != false else { return "none" }
        muteWatchdog?.cancel()
        if let event = muter.restore() { mediaLog.append(event.rawValue) }
        if let event = media.resumeIfWePaused() { mediaLog.append(event.rawValue) }
        defer { mediaLog = [] }
        return mediaLog.isEmpty ? "none" : mediaLog.joined(separator: ">")
    }

    /// Quit (menu) and SIGTERM (launchctl kickstart/bootout) both restore the
    /// mute flag before the process goes away.
    private func installTerminationRestore() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.muter.restore()
        }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.muter.restore()
            exit(0)
        }
        source.resume()
        signalSource = source
    }

    private func finishButton() {
        if pillOutcome?.isRecoverable == true { outcomeEvent(.recoverTap) }
        else { perform(machine.finishButton()) }
    }
    private func cancel() {
        if pillOutcome != nil { outcomeEvent(.dismissTap) }
        else {
            if machine.state == .idle { capture.end(.cancel) }
            perform(machine.cancel())
        }
    }
    private func escape() {
        if pillOutcome != nil { outcomeEvent(.escape) }
        else {
            if machine.state == .idle { capture.end(.cancel) }
            perform(machine.cancel())
        }
    }

    private func perform(_ action: DictationAction) {
        switch action {
        case .none: break
        case .startRecording: beginRecording()
        case .finishRecording: endRecording()
        case .cancelRecording: cancelAll()
        }
    }

    // MARK: - Flow

    private func beginRecording() {
        clearOutcome()
        logKeyStates()
        sessionPolicy = EnginePolicy(mode: engineMode, fallback: forceFallback, quota: quotaStore.current, now: Date())
        if let dependencies { recordingTarget = dependencies.frontmostTarget() }
        else { recordingTarget = Self.frontmostTarget() }
        generation = CaptureEpoch()
        let token = generation
        btStart = BluetoothProfile.sample()
        btEndNotePending = true
        recordingStarted = Date()
        micStarting = true
        pill.show(.warming)
        statusItem?.setRecording(true)
        // BT3: establish the recording boundary before either asynchronous start
        // completes, so built-in bridge audio feeds the existing transcribers.
        recorder.resetCapture()
        attachTranscribers()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cancelled = { self.generation !== token || self.machine.state != .recording }
            let ready = await self.capture.beginRecordingAsync(at: ProcessInfo.processInfo.systemUptime,
                start: { try await self.recorder.startAsync(device: $0) },
                rebuild: { try await self.recorder.rebuildAsync() },
                wait: { seconds in await self.captureScheduler.wait(seconds) },
                isCancelled: cancelled)
            guard !cancelled() else { return }
            self.micStarting = false
            if !ready, self.fakeTranscript == nil {
                Self.note("warm_phase=\(self.capture.warmup.phase) engine_running=\(self.recorder.isRunning)")
                self.fail(reason: "mic_\(self.micAvailable ? "start" : "denied")", duration: 0, bytes: 0, latencyMs: 0)
                return
            }
            self.traceFocus("pill shown")
        }
    }

    private func attachTranscribers() {
        if fakeTranscript == nil {
            let engine = dependencies?.makeApple() ?? AppleTranscriber()
            apple = engine
            if chunkedEnabled {
                let keys = keyStore
                let incremental = sessionPolicy.usesCleanup && sessionPolicy.usesGroqCleanup ? IncrementalCleaner(cleaner: groqCleaner) : nil
                incrementalCleaner = incremental
                let streaming = GroqChunkedTranscriber(transport: dependencies?.sttTransport ?? URLSessionTransport(timeout: 30), apiKey: {
                    guard let key = keys.key(for: "groq-api") else { throw TranscriptionError.missingKey }
                    return key
                }, prompt: prompt, onChunkText: { index, text in incremental?.append(index: index, text: text) },
                   onGroqRateLimit: { [rateLimitRelay] in rateLimitRelay.observe($0) })
                chunked = streaming
                recorder.onPCMChunk = { pcm in
                    engine.append(pcm)
                    streaming.append(pcm)
                }
            } else {
                recorder.onPCMChunk = { pcm in engine.append(pcm) }
            }
            Task { try? await engine.start() }
            if sessionPolicy.usesCleanup, sessionPolicy.usesGroqCleanup {
                Task { [groqCleaner] in await groqCleaner.warmUp() }
            }
        } else {
            recorder.onPCMChunk = nil
        }
    }

    private func dropTranscriber() {
        incrementalCleaner?.cancel()
        incrementalCleaner = nil
        recorder.onPCMChunk = nil
        chunked?.cancel()
        chunked = nil
    }

    private func endRecording() {
        if micStarting && !recorder.bridgeHasAudio {
            machine = DictationStateMachine()
            cancelAll()
            return
        }
        micStarting = false
        statusItem?.setRecording(false)
        let finishedAt = Date()
        let finishClock = DispatchTime.now()
        let warmMs = capture.warmup.warmMs
        let samples = capture.end(.finished(.ok)) // flush final audio before detaching sessions
        recorder.onPCMChunk = nil
        let mediaEvents = resumeMedia()
        let duration = finishedAt.timeIntervalSince(recordingStarted ?? finishedAt)
        let bytes = 44 + samples.count * 2
        let appleSession = apple
        apple = nil
        let chunkedSession = chunked
        chunked = nil
        let incrementalSession = incrementalCleaner
        incrementalSession?.seal()   // the last chunk's text lands after this tap
        let myGeneration = generation
        pill.show(.transcribing)

        if fakeTranscript == nil, AudioLevel.isSilent(samples) {
            appleSession?.cancel()
            chunkedSession?.cancel()
            machine.transcriptionFinished()
            fail(reason: "silence", duration: duration, bytes: bytes, latencyMs: 0)
            return
        }

        let fake = fakeTranscript
        let localCleaner = self.localCleaner
        let groqCleaner = self.groqCleaner
        let groqSTT = self.groqSTT
        let policy = sessionPolicy
        let shadowEnabled = self.shadowEnabled && policy.usesGroqSTT
        let vocabularyPrompt = self.prompt
        var timeline = Timeline(media: mediaEvents, warmMs: warmMs, capture: recorder.stats, micFallback: capture.usedBuiltIn, btStart: btStart,
                                capturedSeconds: Double(samples.count) / AudioRecorder.sampleRate,
                                peakDBFS: AudioLevel.peakDBFS(samples))
        Task {
            var pipeline = PipelineReport()
            var shadow: Task<(appleNames: Int, groqNames: Int, milliseconds: Int)?, Never>?
            var result: Result<String, Error>
            if let fake {
                result = .success(fake)
            } else {
                let sttStart = Date()
                let stt = await policy.transcribe(apple: appleSession, chunked: chunkedSession, at: finishClock)
                result = stt.result
                pipeline.path = stt.path
                if let joined = stt.joined {
                    pipeline.chunks = joined.chunks
                    pipeline.lastChunkMs = joined.lastChunkMs
                    timeline.chunked = joined
                    if pipeline.path == "apple" { pipeline.chunkFallback = joined.failedCount }
                    if shadowEnabled, pipeline.path == "groq-chunked" {
                        shadow = Task.detached {
                            let raw = await stt.appleFinal.value ?? ""
                            guard ShadowScore.overlap(raw) >= 0.60 else { return nil }
                            return (ShadowScore.nameCount(raw), ShadowScore.nameCount(joined.text), 0)
                        }
                    }
                }
                pipeline.sttMs = Int(Date().timeIntervalSince(chunkedSession == nil ? sttStart : finishedAt) * 1000)
                if shadowEnabled, pipeline.path == "apple", case .success(let raw) = result,
                   ShadowScore.overlap(raw) >= 0.60 {
                    let appleNames = ShadowScore.nameCount(raw)
                    shadow = Task.detached {
                        let wav = WAVEncoder.encode(samples: WAVEncoder.pcm16(from: samples), sampleRate: 24_000)
                        let start = DispatchTime.now()
                        let groqRaw = (try? await groqSTT.transcribe(wav: wav, prompt: vocabularyPrompt)) ?? ""
                        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                        return (appleNames, ShadowScore.nameCount(groqRaw), elapsed)
                    }
                }
                // generation/machine are main-thread state: never read them from this task.
                guard await MainActor.run(body: { myGeneration === self.generation && self.machine.state == .transcribing }) else {
                    incrementalSession?.cancel()
                    return
                }
                timeline.cleanupCalls = incrementalSession?.callCount ?? 0
                if incrementalSession?.needsFallback == true {
                    pipeline.cleanupMode = "incremental_fallback"
                    timeline.cleanupFallbackReason = incrementalSession?.fallbackReason
                }
                if case .success(let raw) = result, !raw.isEmpty, (!policy.usesCleanup || !TranscriptCleaner.shouldClean(raw)) {
                    incrementalSession?.cancel()
                    pipeline.cleanup = policy.usesCleanup ? "skipped:short" : "skipped:capture_only"
                    timeline.incrementalSkipped = pipeline.path != "groq-chunked" ? "not_chunked" :
                        (pipeline.chunks ?? 0) <= 2 ? "short" : "short_text"
                } else if case .success(let raw) = result, !raw.isEmpty {
                    let cleanStart = Date()
                    let incremental: IncrementalCleaner.Result?
                    if pipeline.path == "groq-chunked", let incrementalSession {
                        incremental = await incrementalSession.finish(totalChunks: pipeline.chunks ?? 0, rawText: raw,
                            single: { fullRaw in
                                let outcome = await policy.clean(fullRaw, groq: groqCleaner, local: localCleaner)
                                return .init(text: outcome.text, label: outcome.label, model: outcome.model,
                                             stats: outcome.stats, calls: outcome.calls)
                            })
                    } else {
                        incrementalSession?.cancel()
                        incremental = nil
                    }
                    guard await MainActor.run(body: { myGeneration === self.generation && self.machine.state == .transcribing }) else { return }
                    pipeline.cleanupMode = incremental?.mode ?? "single"
                    timeline.cleanupCalls = incremental?.calls ?? 0
                    timeline.cleanupFallbackReason = incremental?.fallbackReason
                    timeline.incrementalSkipped = incremental?.skippedReason ??
                        (pipeline.path != "groq-chunked" ? "not_chunked" : nil)
                    if let text = incremental?.text {
                        pipeline.text = text
                        pipeline.cleanup = incremental?.single?.label ?? "ok"
                        pipeline.cleanupModel = incremental?.single?.model ?? groqCleaner.model
                        timeline.cleanup = incremental?.stats
                    } else {
                        let outcome = await policy.clean(raw, groq: groqCleaner, local: localCleaner)
                        pipeline.text = outcome.text
                        pipeline.cleanup = outcome.label
                        pipeline.cleanupModel = outcome.model
                        timeline.cleanup = outcome.stats
                        timeline.cleanupCalls += outcome.calls
                    }
                    pipeline.cleanupMs = Int(Date().timeIntervalSince(cleanStart) * 1000)
                }
                timeline.cleanupMode = pipeline.cleanupMode
            }
            if fake != nil { timeline.incrementalSkipped = "disabled_fake" }
            if !policy.usesCleanup { pipeline.cleanupMode = "none"; timeline.incrementalSkipped = nil }
            timeline.cleanupMode = pipeline.cleanupMode
            if pipeline.cleanupMode == "single", timeline.incrementalSkipped == nil {
                timeline.incrementalSkipped = pipeline.path == "groq-chunked" ? "none_cleanable_before_finish" : "not_chunked"
            }
            if let shadow, case .success(let raw) = result {
                let pastedNames = ShadowScore.nameCount(pipeline.text ?? raw)
                Task.detached {
                    guard let counts = await shadow.value else { return }
                    Self.note(ShadowScore.line(appleNames: counts.appleNames, pastedNames: pastedNames,
                                              groqNames: counts.groqNames, milliseconds: counts.milliseconds))
                }
            }
            let report = pipeline
            let finalTimeline = timeline
            let finalResult = result
            await MainActor.run {
                guard myGeneration === self.generation, self.machine.state == .transcribing else { return }
                self.incrementalCleaner?.cancel()
                self.incrementalCleaner = nil
                self.machine.transcriptionFinished()
                let latency = Int(Date().timeIntervalSince(finishedAt) * 1000)
                let entry = { (chars: Int, app: String, outcome: DictationOutcome) -> DictationLogEntry in
                    var e = DictationLogEntry(time: Date(), durationSeconds: duration, audioBytes: bytes, latencyMs: latency,
                                              chars: chars, frontmostBundleID: app, outcome: outcome)
                    e.incrementalSkipped = report.cleanupMode == "single" ? finalTimeline.incrementalSkipped : nil
                    e.hedges = finalTimeline.chunked?.hedges
                    e.hedgeWins = finalTimeline.chunked?.hedgeWins
                    if fake == nil {
                        e.path = report.path
                        e.sttMs = report.sttMs
                        e.cleanupMs = report.cleanupMs
                        e.cleanupModel = report.cleanupModel
                        e.cleanup = report.cleanup
                        e.cleanupMode = report.cleanupMode
                        e.chunks = report.chunks
                        e.lastChunkMs = report.lastChunkMs
                        e.chunkFallback = report.chunkFallback
                    }
                    return e
                }
                switch finalResult {
                case .success(let raw) where !raw.isEmpty:
                    let text = report.text ?? raw
                    if fake == nil, ShadowScore.overlap(raw) >= 0.60 {
                        Self.note(ShadowScore.namesLine(rawNames: ShadowScore.nameCount(raw),
                                                       pastedNames: ShadowScore.nameCount(text), path: report.path,
                                                       pastedText: text))
                    }
                    let start = self.recordingTarget
                    let publicTimeline = DictationTimeline(latency_ms: latency, stt_ms: report.sttMs,
                        cleanup_ms: report.cleanupMs, chunks: report.chunks, path: report.path,
                        cleanup_mode: policy.usesCleanup ? report.cleanupMode : "none", fallback: policy.fallbackLabel)
                    policy.deliver(text, transcript: { self.engineOnTranscript?($0, publicTimeline) }, paste: { text in
                        self.inserter.insert(text, shouldInsert: {
                            let now = self.currentTarget()
                            let app = now?.bundleID ?? ""
                            switch InsertionTarget.decide(start: start, now: now) {
                            case .paste:
                                if let cleanup = report.cleanup, cleanup != "skipped:short", cleanup.hasPrefix("skipped:") || cleanup.hasPrefix("rejected:") {
                                    self.showOutcome(.rawPasted(cleanup))
                                } else {
                                    self.showOutcome(.ok)
                                }
                                self.traceFocus("pasting")
                                self.appendLog(entry(text.count, app, .ok), fallback: policy.fallbackFields)
                                return true
                            case .hold:
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                self.rememberHeldDictation(text)
                                self.showOutcome(.held("focus_changed"), text: text)
                                self.appendLog(entry(text.count, app, .held("focus_changed")), fallback: policy.fallbackFields)
                                return false
                            }
                        })
                    })
                    if !policy.usesPaste {
                        self.clearOutcome()
                        self.appendLog(entry(text.count, AppController.frontmostBundleID(), .ok), fallback: policy.fallbackFields)
                    }
                case .success:
                    self.showOutcome(.held("no_stt"))
                    self.appendLog(entry(0, AppController.frontmostBundleID(), .held("no_stt")), fallback: policy.fallbackFields)
                case .failure(let error):
                    let reason = (error as? TranscriptionError)?.logReason ?? "unknown"
                    if reason == "rejected_no_stt" {
                        self.showOutcome(.held("no_stt"))
                        self.appendLog(entry(0, AppController.frontmostBundleID(), .held("no_stt")), fallback: policy.fallbackFields)
                    } else {
                        self.showOutcome(.error(reason))
                        self.appendLog(entry(0, AppController.frontmostBundleID(), .error(reason)), fallback: policy.fallbackFields)
                    }
                }
                if fake == nil {
                    AppController.note(finalTimeline.line(sttMs: report.sttMs, cleanupMs: report.cleanupMs, path: report.path,
                                                          chunkFallback: report.chunkFallback,
                                                          keyState: self.keyStore.missing(for: "groq-api")?.rawValue ?? "ok") + (policy.fallbackFields.map { " fallback=\($0)" } ?? ""))
                }
            }
        }
    }

    /// Groq first (fastest + best measured). If Groq fails or is slower than
    /// its 1.5 s deadline, the local model runs; raw text is used if both fail.
    /// The log says which one produced the text.
    static func cleanUp(_ raw: String, groq: TranscriptCleaner, local: TranscriptCleaner, forceLocal: Bool = false) async
        -> (text: String, label: String, model: String, stats: TranscriptCleaner.Stats?, calls: Int) {
        if !forceLocal, let (text, stats) = try? await groq.cleanWithStats(raw) {
            return (text, "ok", groq.model, stats, 1)
        }
        if Task.isCancelled { return (raw, "skipped:cancelled", groq.model, nil, 1) }
        let deadline = max(2.5, 0.8 + Double(raw.count) / 4 / 45)
        let localTransport: HTTPTransport = local.transport is URLSessionTransport ? URLSessionTransport(timeout: deadline) : local.transport
        var timedLocal = TranscriptCleaner(transport: localTransport, endpoint: local.endpoint,
                                           model: local.model, vocabulary: local.vocabulary, apiKey: local.apiKey)
        timedLocal.reloadVocabularyFromHints = local.reloadVocabularyFromHints
        timedLocal.hintsSentence = local.hintsSentence
        timedLocal.timeoutInterval = deadline
        do {
            let (text, stats) = try await timedLocal.cleanWithStats(raw)
            return (text, "fallback_local", local.model, stats, forceLocal ? 1 : 2)
        } catch TranscriptionError.rejected(let reason) {
            return (raw, "rejected:\(reason)", local.model, nil, forceLocal ? 1 : 2)
        } catch {
            return (raw, "skipped:\((error as? TranscriptionError)?.logReason ?? "error")", local.model, nil, forceLocal ? 1 : 2)
        }
    }

    /// One stderr line per dictation: where the time went. Counts and ms only.
    struct Timeline {
        var media: String
        var warmMs: Int?
        var capture: AudioRecorder.CaptureStats
        var micFallback = false
        var btStart = "none"
        var capturedSeconds: Double
        var peakDBFS: Double
        var cleanup: TranscriptCleaner.Stats?
        var chunked: GroqChunkedTranscriber.Result?
        var cleanupMode = "single"
        var cleanupCalls = 0
        var cleanupFallbackReason: String?
        var incrementalSkipped: String?

        func line(sttMs: Int?, cleanupMs: Int?, path: String, chunkFallback: Int?, keyState: String) -> String {
            var fields = [
                "timeline:", "keys=groq:\(keyState)", "bt_start=\(btStart)",
                "mic=\"\(capture.device)\"", "warm_ms=\(warmMs.map(String.init) ?? "-")", "media=\(media)",
                "conflict=\(AppController.conflictingDictationApps())", "fmt=\(capture.startFormat)",
                "engine_start_ms=\(capture.engineStartMs)", "first_buffer_ms=\(capture.firstBufferMs.map(String.init) ?? "-")",
                "format_changes=\(capture.formatChanges)", "config_changes=\(capture.configChanges)",
                "bridge_ms=\(capture.bridgeMs.map(String.init) ?? "-")", "bridge_src=\(capture.bridgeSource)",
                String(format: "captured_s=%.1f", capturedSeconds), String(format: "peak_dbfs=%.1f", peakDBFS),
                "path=\(path)", "stt_ms=\(sttMs.map(String.init) ?? "-")",
                "cleanup_first_byte_ms=\(cleanup?.firstByteMs.map(String.init) ?? "-")", "cleanup_ms=\(cleanupMs.map(String.init) ?? "-")",
                "completion_tokens=\(cleanup?.completionTokens.map(String.init) ?? "-")",
                "cleanup_mode=\(cleanupMode)", "cleanup_calls=\(cleanupCalls)",
            ]
            if let cleanupFallbackReason { fields.append("fallback_reason=\(cleanupFallbackReason)") }
            if cleanupMode == "single", let incrementalSkipped {
                fields.append("incremental_skipped=\(incrementalSkipped)")
            }
            if let reason = capture.bridgeReason { fields.append("bridge_reason=\(reason)") }
            if micFallback { fields.append("mic_fallback=builtin") }
            if let chunked {
                fields += ["chunks=\(chunked.chunks)", "last_chunk_ms=\(chunked.lastChunkMs)",
                           "hedges=\(chunked.hedges)", "hedge_wins=\(chunked.hedgeWins)",
                           "rpm_remaining=\(chunked.rateLimits?.rpmRemaining ?? "-")",
                           "rpd_remaining=\(chunked.rateLimits?.rpdRemaining ?? "-")"]
                for call in chunked.calls {
                    fields.append("chunk_\(call.index)_attempt_\(call.attempt)_ms=\(call.milliseconds)")
                }
                if let limits = chunked.rateLimits {
                    for name in GroqChunkedTranscriber.RateLimits.names where limits.headers[name] != nil {
                        fields.append("\(name)=\(limits.count(name))")
                    }
                }
            }
            if let chunkFallback { fields.append("chunk_fallback=\(chunkFallback)") }
            return fields.joined(separator: " ")
        }
    }

    /// What happened between the finish tap and the paste, for the log.
    struct PipelineReport {
        var cleanupModel: String?
        var path = "apple"
        var sttMs: Int?
        var cleanupMs: Int?
        var cleanup: String?
        var cleanupMode = "single"
        var text: String?
        var chunks: Int?
        var lastChunkMs: Int?
        var chunkFallback: Int?
    }

    private func cancelAll() {
        micStarting = false
        generation = CaptureEpoch()
        statusItem?.setRecording(false)
        let duration = Date().timeIntervalSince(recordingStarted ?? Date())
        capture.end(.cancel) // discard: nothing is kept
        let mediaEvents = resumeMedia()
        if mediaEvents != "-" { AppController.note("cancel media=\(mediaEvents)") }
        dropTranscriber()
        apple?.cancel()
        apple = nil
        pill.hide()
        traceFocus("pill hidden, cancelled")
        log(duration: duration, bytes: 0, latencyMs: 0, chars: 0, app: AppController.frontmostBundleID(), outcome: .cancel)
    }

    private func fail(reason: String, duration: TimeInterval, bytes: Int, latencyMs: Int) {
        generation = CaptureEpoch()
        micStarting = false
        machine = DictationStateMachine()
        capture.end(.fail)
        dropTranscriber()
        apple?.cancel()
        apple = nil
        let mediaEvents = resumeMedia()
        if mediaEvents != "-" { Self.note("fail media=\(mediaEvents)") }
        statusItem?.setRecording(false)
        showOutcome(.error(reason))
        log(duration: duration, bytes: bytes, latencyMs: latencyMs, chars: 0, app: AppController.frontmostBundleID(), outcome: .error(reason))
    }

    private func log(duration: TimeInterval, bytes: Int, latencyMs: Int, chars: Int, app: String, outcome: DictationOutcome) {
        appendLog(DictationLogEntry(
            time: Date(), durationSeconds: duration, audioBytes: bytes, latencyMs: latencyMs,
            chars: chars, frontmostBundleID: app, outcome: outcome
        ), fallback: sessionPolicy.fallbackFields)
    }

    func appendLog(_ entry: DictationLogEntry, fallback: String?) {
        guard let fallback else { DictationLog.append(entry, to: paths.logURL); return }
        // DictateCore's line is unchanged; quota adds only its agreed label.
        do {
            try FileManager.default.createDirectory(at: paths.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: paths.logURL.path) {
                guard FileManager.default.createFile(atPath: paths.logURL.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: paths.logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((entry.formatted() + " fallback=\(fallback)\n").utf8))
        } catch { /* Same best-effort diagnostic behavior as DictationLog. */ }
    }

    private func traceFocus(_ event: String) {
        guard trace else { return }
        AppController.note("\(event) frontmost=\(AppController.frontmostBundleID()) onScreen=\(pill.isOnScreen) frame=\(NSStringFromRect(pill.frame))")
    }

    /// Another dictation app listening for the same ⌥⌥ pastes its own text
    /// alongside ours (seen 01:0x: Wispr Flow reopened → raw + cleaned pasted).
    static func conflictingDictationApps() -> String {
        let ids = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let hits = ids.filter { $0.hasPrefix("com.electron.wispr") }
        return hits.isEmpty ? "none" : "wispr_running"
    }

    private static func frontmostBundleID() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }

    private func currentTarget() -> InsertionTarget? {
        if let dependencies { return dependencies.frontmostTarget() }
        return Self.frontmostTarget()
    }

    private static func frontmostTarget() -> InsertionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return InsertionTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "")
    }

    private func rememberHeldDictation(_ text: String) {
        lastDictationTimer?.invalidate()
        lastDictation = text
        statusItem?.setLastDictationAvailable(true)
        let timer = Timer(timeInterval: 10 * 60, repeats: false) { [weak self] _ in
            self?.lastDictation = nil
            self?.statusItem?.setLastDictationAvailable(false)
            self?.lastDictationTimer = nil
        }
        lastDictationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Diagnostics go to stderr (the LaunchAgent routes it to dictate.stderr.log),
    /// never to dictate.log, and never contain transcript text or the key.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] dictate: \(message)\n".utf8))
    }
}
