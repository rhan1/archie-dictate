import DictateCore

/// Snapshotted at recording start so host preferences cannot reroute an in-flight session.
struct EnginePolicy: Sendable {
    var mode: DictationEngine.Mode = .dictate
    var fallback: FallbackOverride?
    var usesGroq: Bool { fallback != .quota }
    var usesCleanup: Bool { mode == .dictate }
    var usesPaste: Bool { mode == .dictate }
    var fallbackLabel: String? { fallback == .quota ? "quota" : nil }

    func clean(_ raw: String, groq: TranscriptCleaner, local: TranscriptCleaner) async
        -> (text: String, label: String, model: String, stats: TranscriptCleaner.Stats?, calls: Int) {
        guard usesCleanup else { return (raw, "skipped:capture_only", "none", nil, 0) }
        return await AppController.cleanUp(raw, groq: groq, local: local, forceLocal: !usesGroq)
    }

    func deliver(_ text: String, transcript: (String) -> Void, paste: (String) -> Void) {
        transcript(text)
        if usesPaste { paste(text) }
    }
}
