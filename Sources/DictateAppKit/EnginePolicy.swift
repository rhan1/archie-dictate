import Foundation
import DictateCore

/// Snapshotted at recording start so host preferences cannot reroute an in-flight session.
struct EnginePolicy: Sendable {
    var mode: DictationEngine.Mode = .dictate
    var fallback: FallbackOverride?
    /// Per-endpoint quota exhaustion (< 10 % requests left), sampled once at recording start.
    var sttQuotaLow = false
    var cleanupQuotaLow = false
    var usesGroqSTT: Bool { fallback != .quota && !sttQuotaLow }
    var usesGroqCleanup: Bool { fallback != .quota && !cleanupQuotaLow }
    var usesCleanup: Bool { mode == .dictate }
    var usesPaste: Bool { mode == .dictate }
    var fallbackLabel: String? { fallback == .quota || sttQuotaLow || cleanupQuotaLow ? "quota" : nil }
    /// Log/timeline text after `fallback=`; automatic quota adds which endpoint ran low.
    var fallbackFields: String? {
        guard let label = fallbackLabel else { return nil }
        guard fallback == nil else { return label }
        return label + " quota_low=" + (sttQuotaLow && cleanupQuotaLow ? "both" : sttQuotaLow ? "stt" : "cleanup")
    }

    init(mode: DictationEngine.Mode = .dictate, fallback: FallbackOverride? = nil) {
        self.mode = mode; self.fallback = fallback
    }

    /// Automatic fallback only when no manual override is set. Capture-only never cleans up.
    init(mode: DictationEngine.Mode, fallback: FallbackOverride?, quota: GroqQuota, now: Date) {
        self.init(mode: mode, fallback: fallback)
        guard fallback == nil else { return }
        sttQuotaLow = quota.isLow(.stt, at: now)
        cleanupQuotaLow = mode == .dictate && quota.isLow(.cleanup, at: now)
    }

    func clean(_ raw: String, groq: TranscriptCleaner, local: TranscriptCleaner) async
        -> (text: String, label: String, model: String, stats: TranscriptCleaner.Stats?, calls: Int) {
        guard usesCleanup else { return (raw, "skipped:capture_only", "none", nil, 0) }
        return await AppController.cleanUp(raw, groq: groq, local: local, forceLocal: !usesGroqCleanup)
    }

    func deliver(_ text: String, transcript: (String) -> Void, paste: (String) -> Void) {
        transcript(text)
        if usesPaste { paste(text) }
    }
}
