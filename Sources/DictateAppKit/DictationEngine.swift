import AppKit
import DictateCore

public enum Surface: Sendable, Equatable { case pill, none }
public enum FallbackOverride: Sendable, Equatable { case quota }

public enum DictationState: Sendable, Equatable {
    case idle, warming, recording(level: Double), transcribing, pasted
    case held(preview: String), error(word: String)

    static func outcome(_ kind: PillOutcome.Kind, text: String? = nil) -> Self {
        if case .held = kind, let text, !text.isEmpty { return .held(preview: text) }
        if kind == .ok { return .pasted }
        return .error(word: PillOutcome(kind).label ?? "error")
    }
}

/// Counts and labels only; no audio or transcript is retained here.
public struct DictationTimeline: Sendable, Equatable {
    public let latency_ms: Int
    public let stt_ms: Int?
    public let cleanup_ms: Int?
    public let chunks: Int?
    public let path: String
    public let cleanup_mode: String
    public let fallback: String?

    public init(latency_ms: Int, stt_ms: Int?, cleanup_ms: Int?, chunks: Int?, path: String,
                cleanup_mode: String, fallback: String? = nil) {
        self.latency_ms = latency_ms; self.stt_ms = stt_ms; self.cleanup_ms = cleanup_ms
        self.chunks = chunks; self.path = path; self.cleanup_mode = cleanup_mode; self.fallback = fallback
    }
}

/// Embeddable controls over the standalone app's existing pipeline. Construction
/// neither starts audio nor installs hotkeys, prompts, menus, or model downloads.
@MainActor public final class DictationEngine {
    public enum Mode: Sendable, Equatable { case dictate, captureOnly }
    public var onState: (DictationState) -> Void = { _ in }
    public var onTranscript: (String, DictationTimeline) -> Void = { _, _ in }
    public var onGroqRateLimit: ((GroqRateLimit) -> Void)?
    /// Every diagnostic line (timeline, keys, bridge, media; counts only, never text), on any
    /// thread. Standalone Dictate writes these to its stderr log; a host should tee them to its own.
    /// Process-wide: the most recently set engine's sink receives them.
    public var onDiagnostic: (@Sendable (String) -> Void)? {
        didSet { AppController.setNoteSink(onDiagnostic) }
    }
    public var surface: Surface {
        get { controller.engineSurface }
        set { controller.engineSurface = newValue }
    }
    public var mode: Mode {
        get { controller.engineMode }
        set { controller.engineMode = newValue }
    }
    /// Where Groq's rate-limit counts are persisted (counts only). Relocate via `init(quotaFileURL:)`.
    public var quotaFileURL: URL { controller.quotaStore.fileURL }
    /// Latest counts from every Groq response this engine has seen (also read from the file at launch).
    public var groqQuota: GroqQuota { controller.quotaStore.current }
    public var forceFallback: FallbackOverride? {
        get { controller.forceFallback }
        set { controller.forceFallback = newValue }
    }

    // Standalone AppController owns its facade; hosts' facades own their controller.
    private unowned let controller: AppController
    private let ownedController: AppController?

    public init(keyStore: KeyStore, paths: AppPaths, surface: Surface = .pill, mode: Mode = .dictate,
                quotaFileURL: URL? = nil) {
        let controller = AppController(keyStore: keyStore, paths: paths, surface: surface, mode: mode, quotaFileURL: quotaFileURL)
        self.controller = controller
        ownedController = controller
        bind()
    }

    init(controller: AppController) {
        self.controller = controller
        ownedController = nil
        bind()
    }

    private func bind() {
        controller.engineOnState = { [weak self] in self?.onState($0) }
        controller.engineOnTranscript = { [weak self] in self?.onTranscript($0, $1) }
        controller.engineOnGroqRateLimit = { [weak self] in self?.onGroqRateLimit?($0) }
    }

    public func start() { controller.engineStart() }
    public func finish() { controller.engineFinish() }
    /// Undoes a mute left by a host that quit or crashed mid-dictation; call once at host launch.
    /// Returns the event (`mute_recovered=1`, `restore_failed`) or nil when nothing was pending.
    @discardableResult public func recoverStaleMute() -> String? { controller.engineRecoverStaleMute() }
    public func cancel() { controller.engineCancel() }
    public func escape() { controller.engineEscape() }
    public func pasteHeld() { controller.enginePasteHeld() }
    public func copyHeld() { controller.engineCopyHeld() }

    func handle(_ signal: TapSignal) { controller.engineHotkey(signal) }
}
