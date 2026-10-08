import AppKit
import DictateCore

/// Wires the hotkey, recorder, pill, transcription and paste together around
/// the pure DictationStateMachine.
public final class AppController {
    public static let vocabularyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects/-Users-razakhan/memory/reference-raza-vocabulary.md")

    private var machine = DictationStateMachine()
    private let hotkeys = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let pill = PillPanel()
    private let statusItem = StatusItemController()
    private let inserter = TextInserter()
    /// Batch STT: v1.1 keeps it only as the fallback when the Realtime socket
    /// cannot be used.
    private let client = TranscriptionClient(transport: URLSessionTransport(timeout: 60)) {
        try KeychainAPIKey.read()   // D2: read at use time, never cached
    }
    private let prompt: String
    private let cleaner: TranscriptCleaner
    /// The Realtime session for the current (or about-to-start) dictation.
    private var transcriber: RealtimeTranscriber?
    private var speculativeOpenWork: DispatchWorkItem?
    /// L4 lever: bypasses the network with a fixed transcript.
    private let fakeTranscript = ProcessInfo.processInfo.environment["DICTATE_FAKE_TRANSCRIPT"]
    /// QA lever: notes pill show/hide with the frontmost app (G4) to stderr.
    private let trace = ProcessInfo.processInfo.environment["DICTATE_TRACE"] == "1"

    private var recordingStarted: Date?
    private var capTimer: Timer?
    private var generation = 0
    private var micAvailable = false

    public init() {
        if !FileManager.default.fileExists(atPath: AppController.vocabularyURL.path) {
            AppController.note("vocabulary file missing at \(AppController.vocabularyURL.path); using seed terms only")
        }
        prompt = Vocabulary.buildPrompt(fileURL: AppController.vocabularyURL)
        // A4: the same vocabulary feeds the STT prompt and the cleanup prompt.
        cleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: TranscriptCleaner.deadline),
                                    vocabulary: prompt) { try KeychainAPIKey.read() }
    }

    public func start() {
        hotkeys.onSignal = { [weak self] signal in self?.hotkey(signal) }
        hotkeys.onEscape = { [weak self] in self?.cancel() }
        pill.onCancel = { [weak self] in self?.cancel() }
        pill.onFinish = { [weak self] in self?.finishButton() }
        statusItem.onToggle = { [weak self] in self?.doubleTap() }
        recorder.onLevel = { [weak self] level in self?.pill.push(level: level) }

        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let tapOK = hotkeys.start()
        AppController.note("started pid=\(getpid()) accessibility=\(trusted) eventTap=\(tapOK) promptChars=\(prompt.count) fake=\(fakeTranscript != nil)")
        if !tapOK {
            // Without the grant there is no tap; retry quietly until the user approves.
            retryTapUntilGranted()
        }
        if !trusted { watchAccessibilityGrant() }
        AudioRecorder.requestMicrophoneAccess { [weak self] granted in
            self?.micAvailable = granted
            AppController.note("microphone=\(granted)")
        }
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

    private func doubleTap() { perform(machine.doubleTap()) }

    /// ⌥⌥ starts, one clean ⌥ tap finishes (A2). A clean tap while idle may be
    /// the first half of a double-tap, so the socket is opened right then to
    /// hide its ~0.7 s handshake (A1); it is dropped if no double-tap follows.
    private func hotkey(_ signal: TapSignal) {
        if signal == .tap, machine.state == .idle { openTranscriberSpeculatively() }
        perform(machine.handle(signal))
    }

    private func openTranscriberSpeculatively() {
        guard fakeTranscript == nil else { return }
        if transcriber == nil || transcriber?.hasFailed == true {
            let session = RealtimeTranscriber(transport: URLSessionWebSocketTransport(), prompt: prompt) {
                try KeychainAPIKey.read()
            }
            transcriber = session
            Task { try? await session.open() }
        }
        speculativeOpenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.machine.state == .idle else { return }
            self.transcriber?.close()
            self.transcriber = nil
        }
        speculativeOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    private func finishButton() { perform(machine.finishButton()) }
    private func cancel() { perform(machine.cancel()) }

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
        generation += 1
        recordingStarted = Date()
        speculativeOpenWork?.cancel()
        if fakeTranscript == nil {
            if transcriber == nil || transcriber?.hasFailed == true {
                openTranscriberSpeculatively()
                speculativeOpenWork?.cancel()
            }
            let session = transcriber
            recorder.onPCMChunk = { pcm in session?.append(pcm) }
            Task { [cleaner] in await cleaner.warmUp() }
        } else {
            recorder.onPCMChunk = nil
        }
        do {
            try recorder.start()
        } catch {
            if fakeTranscript == nil {
                machine = DictationStateMachine()
                dropTranscriber()
                fail(reason: "mic_\(micAvailable ? "start" : "denied")", duration: 0, bytes: 0, latencyMs: 0)
                return
            }
        }
        statusItem.setRecording(true)
        pill.show(.recording)
        traceFocus("pill shown")
        capTimer?.invalidate()
        capTimer = Timer.scheduledTimer(withTimeInterval: DictationLimits.maxDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.perform(self.machine.maxDurationReached())
        }
    }

    private func dropTranscriber() {
        transcriber?.close()
        transcriber = nil
        recorder.onPCMChunk = nil
    }

    private func endRecording() {
        capTimer?.invalidate()
        statusItem.setRecording(false)
        let finishedAt = Date()
        let samples = recorder.stop()      // also flushes the last chunk to the socket
        recorder.onPCMChunk = nil
        let duration = finishedAt.timeIntervalSince(recordingStarted ?? finishedAt)
        let bytes = 44 + samples.count * 2
        let session = transcriber
        transcriber = nil
        let myGeneration = generation
        pill.show(.transcribing)

        if fakeTranscript == nil, AudioLevel.isSilent(samples) {
            session?.close()
            machine.transcriptionFinished()
            fail(reason: "silence", duration: duration, bytes: bytes, latencyMs: 0)
            return
        }

        let fake = fakeTranscript
        let prompt = self.prompt
        let client = self.client
        let cleaner = self.cleaner
        Task {
            var pipeline = PipelineReport()
            let result: Result<String, Error>
            if let fake {
                result = .success(fake)
            } else {
                let sttStart = Date()
                result = await Self.transcribe(session: session, samples: samples, client: client, prompt: prompt, report: &pipeline)
                pipeline.sttMs = Int(Date().timeIntervalSince(sttStart) * 1000)
                if case .success(let raw) = result, !raw.isEmpty, !TranscriptCleaner.shouldClean(raw) {
                    pipeline.cleanup = "skipped:short"
                } else if case .success(let raw) = result, !raw.isEmpty {
                    let cleanStart = Date()
                    do {
                        pipeline.text = try await cleaner.clean(raw)
                        pipeline.cleanup = "ok"
                    } catch {
                        pipeline.text = raw
                        pipeline.cleanup = "skipped:\((error as? TranscriptionError)?.logReason ?? "error")"
                    }
                    pipeline.cleanupMs = Int(Date().timeIntervalSince(cleanStart) * 1000)
                }
            }
            let report = pipeline
            await MainActor.run {
                guard myGeneration == self.generation, self.machine.state == .transcribing else { return }
                self.machine.transcriptionFinished()
                let latency = Int(Date().timeIntervalSince(finishedAt) * 1000)
                let entry = { (chars: Int, app: String, outcome: DictationOutcome) -> DictationLogEntry in
                    var e = DictationLogEntry(time: Date(), durationSeconds: duration, audioBytes: bytes, latencyMs: latency,
                                              chars: chars, frontmostBundleID: app, outcome: outcome)
                    if fake == nil {
                        e.path = report.path
                        e.sttMs = report.sttMs
                        e.cleanupMs = report.cleanupMs
                        e.cleanupModel = report.cleanup == nil ? nil : cleaner.model
                        e.cleanup = report.cleanup
                    }
                    return e
                }
                switch result {
                case .success(let raw) where !raw.isEmpty:
                    let text = report.text ?? raw
                    self.pill.hide()
                    self.traceFocus("pill hidden, pasting")
                    let app = AppController.frontmostBundleID()
                    self.inserter.insert(text)
                    DictationLog.append(entry(text.count, app, .ok))
                case .success:
                    self.pill.show(.error)
                    DictationLog.append(entry(0, AppController.frontmostBundleID(), .error("empty_transcript")))
                case .failure(let error):
                    let reason = (error as? TranscriptionError)?.logReason ?? (error as? RealtimeError)?.logReason ?? "unknown"
                    self.pill.show(.error)
                    DictationLog.append(entry(0, AppController.frontmostBundleID(), .error(reason)))
                }
            }
        }
    }

    /// What happened between the finish tap and the paste, for the log.
    struct PipelineReport {
        var path = "realtime"
        var sttMs: Int?
        var cleanupMs: Int?
        var cleanup: String?
        var text: String?
    }

    /// A1: the streamed Realtime transcript; the batch upload only when the
    /// socket never opened (1.5 s) or failed.
    private static func transcribe(session: RealtimeTranscriber?, samples: [Float], client: TranscriptionClient,
                                   prompt: String, report: inout PipelineReport) async -> Result<String, Error> {
        if let session, session.isConnected, !session.hasFailed {
            do {
                let text = try await session.finish(timeout: 5)
                session.close()
                return .success(text)
            } catch {
                session.close()
                note("realtime failed (\((error as? RealtimeError)?.logReason ?? "error")); falling back to batch")
            }
        } else {
            session?.close()
        }
        report.path = "batch"
        let wav = WAVEncoder.encode(samples: WAVEncoder.pcm16(from: samples), sampleRate: Int(AudioRecorder.sampleRate))
        do { return .success(try await client.transcribe(wav: wav, prompt: prompt)) }
        catch { return .failure(error) }
    }

    private func cancelAll() {
        capTimer?.invalidate()
        generation += 1
        statusItem.setRecording(false)
        let duration = Date().timeIntervalSince(recordingStarted ?? Date())
        _ = recorder.stop()   // discard: nothing is kept
        dropTranscriber()
        pill.hide()
        traceFocus("pill hidden, cancelled")
        log(duration: duration, bytes: 0, latencyMs: 0, chars: 0, app: AppController.frontmostBundleID(), outcome: .cancel)
    }

    private func fail(reason: String, duration: TimeInterval, bytes: Int, latencyMs: Int) {
        statusItem.setRecording(false)
        pill.show(.error)
        log(duration: duration, bytes: bytes, latencyMs: latencyMs, chars: 0, app: AppController.frontmostBundleID(), outcome: .error(reason))
    }

    private func log(duration: TimeInterval, bytes: Int, latencyMs: Int, chars: Int, app: String, outcome: DictationOutcome) {
        DictationLog.append(DictationLogEntry(
            time: Date(), durationSeconds: duration, audioBytes: bytes, latencyMs: latencyMs,
            chars: chars, frontmostBundleID: app, outcome: outcome
        ))
    }

    private func traceFocus(_ event: String) {
        guard trace else { return }
        AppController.note("\(event) frontmost=\(AppController.frontmostBundleID()) onScreen=\(pill.isOnScreen) frame=\(NSStringFromRect(pill.frame))")
    }

    private static func frontmostBundleID() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    }

    /// Diagnostics go to stderr (the LaunchAgent routes it to dictate.stderr.log),
    /// never to dictate.log, and never contain transcript text or the key.
    static func note(_ message: String) {
        FileHandle.standardError.write(Data("[\(ISO8601DateFormatter().string(from: Date()))] dictate: \(message)\n".utf8))
    }
}
