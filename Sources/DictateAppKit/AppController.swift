import AppKit
import DictateCore

/// Wires the hotkey, recorder, pill, transcription and paste together around
/// the pure DictationStateMachine.
/// STT engine: ONE line to switch. Apple on-device won G9 (finish→final ~20 ms,
/// 4/4 names after cleanup); OpenAI Realtime is the alternative.
public enum STTEngine: String { case apple, realtime }

public final class AppController {
    public static let sttEngine: STTEngine =
        ProcessInfo.processInfo.environment["DICTATE_STT"].flatMap(STTEngine.init(rawValue:)) ?? .apple
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
    /// Cleanup runs LOCALLY (Ollama, G7); the cloud model is only the fallback
    /// when Ollama is unreachable.
    private let localCleaner: OllamaCleaner
    private let cloudCleaner: TranscriptCleaner
    /// Cleanup default (G7 round 2): Groq qwen3.8-27b, 10/10 quality, p50 367 ms.
    private let groqCleaner: TranscriptCleaner
    /// Batch STT fallback when the streaming engine fails: Groq whisper first.
    private let groqSTT: TranscriptionClient
    private var apple: AppleTranscriber?
    /// The Realtime session for the current dictation.
    private var transcriber: RealtimeTranscriber?
    /// One idle Realtime socket kept open so no dictation pays the ~0.7 s
    /// handshake; reconnected when it drops, at most once a minute.
    private var warm: RealtimeTranscriber?
    private var warmOpenedAt = Date.distantPast
    private var lastWarmAttempt = Date.distantPast
    private var warmTimer: Timer?
    /// Per-dictation facts for the stderr timeline.
    private var socketOrigin = ""
    /// Bluetooth warm-up: engine pre-started on the first ⌥ tap, WARMING pill
    /// until the first buffer (G8).
    private var warmup = CaptureWarmup()
    private var prewarmExpiry: DispatchWorkItem?
    private var recordingStartMs: UInt64 = 0
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
        // The vocabulary feeds ONLY the cleanup prompt: given to the STT model
        // it was echoed back verbatim instead of the speech (live, 00:27).
        localCleaner = OllamaCleaner(transport: URLSessionTransport(timeout: 30), model: OllamaCleaner.defaultModel,
                                     vocabulary: prompt)
        var groq = TranscriptCleaner(transport: URLSessionTransport(timeout: 1.5), endpoint: TranscriptCleaner.groqEndpoint,
                                     model: "qwen/qwen3.8-27b", vocabulary: prompt) { try KeychainAPIKey.read(service: "groq-api") }
        groq.reasoningEffort = "none"
        groqCleaner = groq
        var whisper = TranscriptionClient(transport: URLSessionTransport(timeout: 30)) { try KeychainAPIKey.read(service: "groq-api") }
        whisper.endpointURL = TranscriptionClient.groqEndpoint
        whisper.modelName = "whisper-large-v3-turbo"
        groqSTT = whisper
        cloudCleaner = TranscriptCleaner(transport: URLSessionTransport(timeout: TranscriptCleaner.deadline),
                                    vocabulary: prompt) { try KeychainAPIKey.read() }
    }

    public func start() {
        hotkeys.onSignal = { [weak self] signal in self?.hotkey(signal) }
        hotkeys.onEscape = { [weak self] in self?.cancel() }
        pill.onCancel = { [weak self] in self?.cancel() }
        pill.onFinish = { [weak self] in self?.finishButton() }
        statusItem.onToggle = { [weak self] in self?.doubleTap() }
        recorder.onLevel = { [weak self] level in self?.pill.push(level: level) }
        recorder.onFirstBuffer = { [weak self] in
            guard let self else { return }
            self.apply(self.warmup.bufferArrived(at: ProcessInfo.processInfo.systemUptime))
        }

        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let tapOK = hotkeys.start()
        AppController.note("started pid=\(getpid()) accessibility=\(trusted) eventTap=\(tapOK) promptChars=\(prompt.count) fake=\(fakeTranscript != nil)")
        if !tapOK {
            // Without the grant there is no tap; retry quietly until the user approves.
            retryTapUntilGranted()
        }
        if !trusted { watchAccessibilityGrant() }
        if fakeTranscript == nil {
            keepWarm(force: true)
            Task { [localCleaner] in await localCleaner.warmUp() }
            if Self.sttEngine == .apple { Task { await AppleTranscriber.ensureAssets() } }
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.keepWarm(force: false) }
            RunLoop.main.add(timer, forMode: .common)
            warmTimer = timer
        }
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
    /// the first half of a double-tap: make sure a warm socket exists.
    private func hotkey(_ signal: TapSignal) {
        if signal == .tap, machine.state == .idle {
            if fakeTranscript == nil, warmIsHealthy == false { keepWarm(force: true) }
            if fakeTranscript == nil { Task { [groqCleaner] in await groqCleaner.warmUp() } }
            prewarmEngine()
        }
        perform(machine.handle(signal))
    }

    /// First ⌥ tap: start the engine now so a Bluetooth headset's profile
    /// switch overlaps the second tap. Stopped silently if no ⌥⌥ follows.
    private func prewarmEngine() {
        apply(warmup.firstTap())
        prewarmExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.machine.state == .idle else { return }
            self.apply(self.warmup.prewarmExpired())
        }
        prewarmExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CaptureWarmup.prewarmTimeout, execute: work)
    }

    private func apply(_ effects: [CaptureWarmup.Effect]) {
        for effect in effects {
            switch effect {
            case .startEngine:
                do { try recorder.start() } catch { AppController.note("engine start failed: \(error)") }
            case .stopEngine:
                _ = recorder.stop()
            case .showWarming:
                pill.show(.warming)
            case .showLive:
                if machine.state == .recording { pill.show(.recording) }
            }
        }
    }

    private var warmIsHealthy: Bool {
        guard let warm else { return false }
        return !warm.hasFailed
    }

    /// Opens the idle socket if there is none (or it dropped). Unforced calls
    /// (the minute timer) reconnect at most once per minute.
    private func keepWarm(force: Bool) {
        guard fakeTranscript == nil, Self.sttEngine == .realtime, !warmIsHealthy else { return }
        guard force || Date().timeIntervalSince(lastWarmAttempt) >= 60 else { return }
        lastWarmAttempt = Date()
        let session = RealtimeTranscriber(transport: URLSessionWebSocketTransport()) { try KeychainAPIKey.read() }
        warm = session
        warmOpenedAt = Date()
        Task { try? await session.open() }
    }

    /// Hands the warm socket to a new dictation (or opens a fresh one).
    private func takeTranscriber() -> RealtimeTranscriber {
        if let warm, !warm.hasFailed {
            self.warm = nil
            socketOrigin = warm.isConnected
                ? "prewarmed(age=\(Int(Date().timeIntervalSince(warmOpenedAt)))s)"
                : "prewarming(age_ms=\(Int(Date().timeIntervalSince(warmOpenedAt) * 1000)))"
            return warm
        }
        warm?.close()
        warm = nil
        socketOrigin = "fresh"
        let session = RealtimeTranscriber(transport: URLSessionWebSocketTransport()) { try KeychainAPIKey.read() }
        Task { try? await session.open() }
        return session
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
        recordingStartMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        if fakeTranscript == nil, Self.sttEngine == .apple {
            socketOrigin = "none(apple)"
            let engine = AppleTranscriber()
            apple = engine
            recorder.onPCMChunk = { pcm in engine.append(pcm) }
            Task { try? await engine.start() }
            Task { [groqCleaner] in await groqCleaner.warmUp() }
        } else if fakeTranscript == nil {
            let session = takeTranscriber()
            transcriber = session
            recorder.onPCMChunk = { pcm in session.append(pcm) }
            Task { [groqCleaner] in await groqCleaner.warmUp() }
        } else {
            recorder.onPCMChunk = nil
        }
        prewarmExpiry?.cancel()
        apply(warmup.recordingStarted(at: ProcessInfo.processInfo.systemUptime))
        recorder.resetCapture()      // pre-roll from the pre-warm is not part of the dictation
        if !recorder.isRunning, fakeTranscript == nil {
            machine = DictationStateMachine()
            warmup.stopped()
            dropTranscriber()
            fail(reason: "mic_\(micAvailable ? "start" : "denied")", duration: 0, bytes: 0, latencyMs: 0)
            return
        }
        statusItem.setRecording(true)
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
        let warmMs = warmup.warmMs
        warmup.stopped()
        let duration = finishedAt.timeIntervalSince(recordingStarted ?? finishedAt)
        let bytes = 44 + samples.count * 2
        let session = transcriber
        transcriber = nil
        let appleSession = apple
        apple = nil
        keepWarm(force: true)   // refill the idle socket on EVERY end path (silence/error included)
        let myGeneration = generation
        pill.show(.transcribing)

        if fakeTranscript == nil, AudioLevel.isSilent(samples) {
            session?.close()
            appleSession?.cancel()
            machine.transcriptionFinished()
            fail(reason: "silence", duration: duration, bytes: bytes, latencyMs: 0)
            return
        }

        let fake = fakeTranscript
        let vocabulary = self.prompt
        let client = self.client
        let localCleaner = self.localCleaner
        let cloudCleaner = self.cloudCleaner
        let groqCleaner = self.groqCleaner
        let groqSTT = self.groqSTT
        var timeline = Timeline(warmMs: warmMs, capture: recorder.stats, socket: socketOrigin, recordingStartMs: recordingStartMs,
                                capturedSeconds: Double(samples.count) / AudioRecorder.sampleRate,
                                peakDBFS: AudioLevel.peakDBFS(samples))
        Task {
            var pipeline = PipelineReport()
            var result: Result<String, Error>
            if let fake {
                result = .success(fake)
            } else {
                let sttStart = Date()
                if let appleSession {
                    result = await Self.transcribeApple(appleSession, samples: samples, groq: groqSTT, openAI: client, report: &pipeline)
                } else {
                    result = await Self.transcribe(session: session, samples: samples, client: client, report: &pipeline)
                }
                pipeline.sttMs = Int(Date().timeIntervalSince(sttStart) * 1000)
                timeline.realtime = session?.timeline
                timeline.segments = session?.segmentCount
                // Echo guard: an STT result that IS the vocabulary list is never pasted.
                if case .success(let raw) = result, PromptEcho.isEcho(raw, vocabulary: vocabulary) {
                    result = .failure(EchoError.promptEcho)
                    timeline.echoGuard = "tripped"
                }
                if case .success(let raw) = result, !raw.isEmpty, !TranscriptCleaner.shouldClean(raw) {
                    pipeline.cleanup = "skipped:short"
                } else if case .success(let raw) = result, !raw.isEmpty {
                    let cleanStart = Date()
                    let outcome = await Self.cleanUp(raw, groq: groqCleaner, local: localCleaner, cloud: cloudCleaner)
                    pipeline.text = outcome.text
                    pipeline.cleanup = outcome.label
                    pipeline.cleanupModel = outcome.model
                    timeline.cleanup = outcome.stats
                    pipeline.cleanupMs = Int(Date().timeIntervalSince(cleanStart) * 1000)
                }
            }
            let report = pipeline
            let finalTimeline = timeline
            let finalResult = result
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
                        e.cleanupModel = report.cleanupModel
                        e.cleanup = report.cleanup
                    }
                    return e
                }
                switch finalResult {
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
                    let reason = (error as? TranscriptionError)?.logReason ?? (error as? RealtimeError)?.logReason
                        ?? (error as? EchoError).map { _ in "prompt_echo" } ?? "unknown"
                    self.pill.show(.error)
                    DictationLog.append(entry(0, AppController.frontmostBundleID(), .error(reason)))
                }
                if fake == nil {
                    AppController.note(finalTimeline.line(sttMs: report.sttMs, cleanupMs: report.cleanupMs, path: report.path))
                }
            }
        }
    }

    enum EchoError: Error { case promptEcho }

    /// Groq first (fastest + best measured). If Groq fails or is slower than
    /// its 1.5 s deadline, the local model runs; OpenAI only if both fail.
    /// The log says which one produced the text.
    private static func cleanUp(_ raw: String, groq: TranscriptCleaner, local: OllamaCleaner, cloud: TranscriptCleaner) async
        -> (text: String, label: String, model: String, stats: TranscriptCleaner.Stats?) {
        if let (text, stats) = try? await groq.cleanWithStats(raw) {
            return (text, "ok", groq.model, stats)
        }
        let timedLocal = OllamaCleaner(transport: local.transport, model: local.model, vocabulary: local.vocabulary,
                                       deadline: max(2.5, 0.8 + Double(raw.count) / 4 / 45))
        do {
            let (text, stats) = try await timedLocal.cleanWithStats(raw)
            return (text, "fallback_local", local.model, stats)
        } catch TranscriptionError.network(let code) where code != "timedOut" {
            if let (text, stats) = try? await cloud.cleanWithStats(raw) {
                return (text, "fallback_openai", cloud.model, stats)
            }
            return (raw, "skipped:all_failed", local.model, nil)
        } catch {
            return (raw, "skipped:\((error as? TranscriptionError)?.logReason ?? "error")", local.model, nil)
        }
    }

    /// G9: Apple on-device first; batch Groq whisper, then OpenAI batch, if it fails.
    private static func transcribeApple(_ engine: AppleTranscriber, samples: [Float], groq: TranscriptionClient,
                                        openAI: TranscriptionClient, report: inout PipelineReport) async -> Result<String, Error> {
        report.path = "apple"
        if let text = try? await engine.finish(), !text.isEmpty { return .success(text) }
        note("apple STT failed or empty; falling back to batch")
        let wav = WAVEncoder.encode(samples: WAVEncoder.pcm16(from: samples), sampleRate: Int(AudioRecorder.sampleRate))
        report.path = "batch_groq"
        if let text = try? await groq.transcribe(wav: wav, prompt: "") { return .success(text) }
        report.path = "batch_openai"
        do { return .success(try await openAI.transcribe(wav: wav, prompt: "")) }
        catch { return .failure(error) }
    }

    /// One stderr line per dictation: where the time went. Counts and ms only.
    struct Timeline {
        var warmMs: Int?
        var capture: AudioRecorder.CaptureStats
        var socket: String
        var recordingStartMs: UInt64
        var capturedSeconds: Double
        var peakDBFS: Double
        var realtime: RealtimeTimeline?
        var segments: Int?
        var cleanup: TranscriptCleaner.Stats?
        var echoGuard = "pass"

        func line(sttMs: Int?, cleanupMs: Int?, path: String) -> String {
            func rel(_ t: UInt64?, from base: UInt64?) -> String {
                guard let t, let base else { return "-" }
                return String(Int64(t) - Int64(base))
            }
            let rt = realtime
            return [
                "timeline:",
                "mic=\"\(capture.device)\"", "warm_ms=\(warmMs.map(String.init) ?? "-")", "fmt=\(capture.startFormat)",
                "engine_start_ms=\(capture.engineStartMs)", "first_buffer_ms=\(capture.firstBufferMs.map(String.init) ?? "-")",
                "format_changes=\(capture.formatChanges)", "config_changes=\(capture.configChanges)",
                String(format: "captured_s=%.1f", capturedSeconds), String(format: "peak_dbfs=%.1f", peakDBFS),
                "stt_engine=\(AppController.sttEngine.rawValue)", "socket=\(socket)", "open_to_created_ms=\(rel(rt?.sessionCreated, from: rt?.openStart))",
                "created_to_updated_ms=\(rel(rt?.sessionUpdated, from: rt?.sessionCreated))",
                "rec_to_first_append_ms=\(rel(rt?.firstAppendSent, from: recordingStartMs))",
                "appended_s=\(String(format: "%.1f", Double(rt?.appendedSamples ?? 0) / AudioRecorder.sampleRate))",
                "tap_to_commit_ms=\(rel(rt?.lastCommitSent, from: rt?.finishCalled))",
                "commit_to_completed_ms=\(rel(rt?.completed, from: rt?.lastCommitSent))",
                "segments=\(segments.map(String.init) ?? "-")", "path=\(path)", "stt_ms=\(sttMs.map(String.init) ?? "-")",
                "echo_guard=\(echoGuard)",
                "cleanup_first_byte_ms=\(cleanup?.firstByteMs.map(String.init) ?? "-")", "cleanup_ms=\(cleanupMs.map(String.init) ?? "-")",
                "pred_accepted=\(cleanup?.acceptedPredictionTokens.map(String.init) ?? "-")",
                "pred_rejected=\(cleanup?.rejectedPredictionTokens.map(String.init) ?? "-")",
                "completion_tokens=\(cleanup?.completionTokens.map(String.init) ?? "-")",
            ].joined(separator: " ")
        }
    }

    /// What happened between the finish tap and the paste, for the log.
    struct PipelineReport {
        var cleanupModel: String?
        var path = "realtime"
        var sttMs: Int?
        var cleanupMs: Int?
        var cleanup: String?
        var text: String?
    }

    /// A1: the streamed Realtime transcript; the batch upload only when the
    /// socket never opened (1.5 s) or failed.
    private static func transcribe(session: RealtimeTranscriber?, samples: [Float], client: TranscriptionClient,
                                   report: inout PipelineReport) async -> Result<String, Error> {
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
        do { return .success(try await client.transcribe(wav: wav, prompt: "")) }   // no STT prompt (echo risk)
        catch { return .failure(error) }
    }

    private func cancelAll() {
        capTimer?.invalidate()
        generation += 1
        statusItem.setRecording(false)
        let duration = Date().timeIntervalSince(recordingStarted ?? Date())
        _ = recorder.stop()   // discard: nothing is kept
        warmup.stopped()
        dropTranscriber()
        apple?.cancel()
        apple = nil
        keepWarm(force: true)
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
