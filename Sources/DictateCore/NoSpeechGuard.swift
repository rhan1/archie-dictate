import Foundation

/// v1.28 FR2-B: garbage is never pasted raw. 2026-11-04 00:43 (19f69203): Raza silent for 22 s; Whisper answered the
/// room noise with prompt echoes ("dives by T Dictate … Thank you."), the cleaner rejected them for their ratio
/// (`fallback_reason=mid_rejected_ratio`), and the dictation degraded to the RAW transcript and pasted it. A cleaner
/// rejection on a dictation whose audio evidence is weak now ends `held:no_speech` (nothing pasted; the text is kept
/// for "Paste last dictation" only). With strong evidence (real speech, cleaner merely unusable) the raw paste stays.
public enum NoSpeechGuard {
    /// Lead-in / artifact words Whisper invents on near-silence (EdgeSentenceGuard's labelled artifacts).
    public static let artifactWords: Set<String> = ["dictate", "thank", "thanks", "you", "bye"]
    /// Weak evidence: the transcript is at least this share of artifact / vocabulary tokens.
    public static let artifactShare = 0.5
    /// Weak evidence: fewer than this share of the dictation's 50 ms windows may hold speech.
    public static let speechShare = 0.1

    public struct Evidence: Equatable, Sendable {
        /// The loudest 50 ms window (dBFS); weak when below −40 dBFS (no always-speech window).
        public var loudestDBFS: Double
        public var speechRatio: Double
        public var artifactRatio: Double
        public var weak: Bool {
            loudestDBFS < 20 * log10(Double(CaptureEvidence.speechRMS)) || speechRatio < NoSpeechGuard.speechShare
                || artifactRatio >= NoSpeechGuard.artifactShare
        }
        /// `nospeech_evidence loudest_dbfs=-38.2 speech_ratio=0.21 artifact_ratio=0.65 weak=1` (counts only).
        public var note: String {
            String(format: "nospeech_evidence loudest_dbfs=%.1f speech_ratio=%.2f artifact_ratio=%.2f weak=%d",
                   loudestDBFS, speechRatio, artifactRatio, weak ? 1 : 0)
        }
    }

    /// The cleaner rejected the text as garbage (`rejected:<reason>` label, or any `*rejected*` fallback reason such as
    /// `mid_rejected_ratio`) AND the dictation is about to paste the raw transcript.
    public static func garbageRejected(cleanupLabel: String?, fallbackReason: String?) -> Bool {
        guard let label = cleanupLabel else { return false }
        let raw = label.hasPrefix("rejected:")
            || (label.hasPrefix("skipped:") && label != "skipped:short" && label != "skipped:capture_only")
        let rejected = label.hasPrefix("rejected:") || (fallbackReason?.contains("rejected") ?? false)
        return raw && rejected
    }

    /// 50 ms RMS windows of `samples` (24 kHz), as `CaptureEvidence` folds them.
    public static func windows(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: CaptureEvidence.windowFrames).compactMap { start in
            let end = min(samples.count, start + CaptureEvidence.windowFrames)
            guard end - start == CaptureEvidence.windowFrames else { return nil }
            var sum = 0.0
            for i in start..<end { sum += Double(samples[i] * samples[i]) }
            return Float((sum / Double(end - start)).squareRoot())
        }
    }

    /// Share of `text`'s word tokens that are artifact words, vocabulary words or single letters (not "a"/"I").
    public static func artifactRatio(_ text: String, vocabulary: String) -> Double {
        func tokens(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter }.map(String.init) }
        let words = tokens(text)
        guard !words.isEmpty else { return 0 }
        let vocab = Set(tokens(vocabulary).filter { $0.count >= 3 })
        let hits = words.filter { ($0.count == 1 && $0 != "a" && $0 != "i") || artifactWords.contains($0) || vocab.contains($0) }
        return Double(hits.count) / Double(words.count)
    }

    public static func evidence(samples: [Float], text: String, vocabulary: String) -> Evidence {
        let windows = windows(samples)
        let loudest = windows.max().map { 20 * log10(max(Double($0), 1e-10)) } ?? -200
        let possible = CaptureEvidence.possibleSpeechWindows(windows, reference: windows).filter { $0 }.count
        return Evidence(loudestDBFS: loudest, speechRatio: windows.isEmpty ? 0 : Double(possible) / Double(windows.count),
                        artifactRatio: artifactRatio(text, vocabulary: vocabulary))
    }
}
