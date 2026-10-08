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
    private let client = TranscriptionClient(transport: URLSessionTransport(timeout: 60)) {
        try KeychainAPIKey.read()   // D2: read at use time, never cached
    }
    private let prompt: String
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
    }

    public func start() {
        hotkeys.onDoubleTap = { [weak self] in self?.doubleTap() }
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
        do {
            try recorder.start()
        } catch {
            if fakeTranscript == nil {
                machine = DictationStateMachine()
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

    private func endRecording() {
        capTimer?.invalidate()
        statusItem.setRecording(false)
        let samples = recorder.stop()
        let duration = Date().timeIntervalSince(recordingStarted ?? Date())
        let wav = WAVEncoder.encode(samples: WAVEncoder.pcm16(from: samples))
        let finishedAt = Date()
        let myGeneration = generation
        pill.show(.transcribing)

        let fake = fakeTranscript
        let prompt = self.prompt
        let client = self.client
        Task {
            let result: Result<String, Error>
            if let fake {
                result = .success(fake)
            } else {
                do { result = .success(try await client.transcribe(wav: wav, prompt: prompt)) }
                catch { result = .failure(error) }
            }
            await MainActor.run {
                guard myGeneration == self.generation, self.machine.state == .transcribing else { return }
                self.machine.transcriptionFinished()
                let latency = Int(Date().timeIntervalSince(finishedAt) * 1000)
                switch result {
                case .success(let text) where !text.isEmpty:
                    self.pill.hide()
                    self.traceFocus("pill hidden, pasting")
                    let app = AppController.frontmostBundleID()
                    self.inserter.insert(text)
                    self.log(duration: duration, bytes: wav.count, latencyMs: latency, chars: text.count, app: app, outcome: .ok)
                case .success:
                    self.fail(reason: "empty_transcript", duration: duration, bytes: wav.count, latencyMs: latency)
                case .failure(let error):
                    let reason = (error as? TranscriptionError)?.logReason ?? "unknown"
                    self.fail(reason: reason, duration: duration, bytes: wav.count, latencyMs: latency)
                }
            }
        }
    }

    private func cancelAll() {
        capTimer?.invalidate()
        generation += 1
        statusItem.setRecording(false)
        let duration = Date().timeIntervalSince(recordingStarted ?? Date())
        _ = recorder.stop()   // discard: nothing is kept
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
