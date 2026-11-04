import Foundation

/// v1.28 FR5-A: Whisper's own confidence, every Groq chunk. Raza's re-test 1 (2026-11-05 06:45:43, trace 97ee30ab.txt):
/// the built-in mic's room noise (≈ −46 dBFS) is over FR2-A's −50 dBFS possible-speech line, so the edge guards kept
/// `Let's see if you can start recording this recording.` — a sentence he never said. Whisper marks such text itself:
/// `verbose_json` segments carry `no_speech_prob`, `avg_logprob` and `compression_ratio`.
///
/// A segment is dropped when
/// - `no_speech_prob ≥ 0.6`, or
/// - `avg_logprob < −1.0` and its time range holds no window ≥ −40 dBFS (`CaptureEvidence.speechRMS`), or
/// - `compression_ratio > 2.4` (a repetition loop),
/// and NEVER when its range holds a window ≥ −40 dBFS and either `no_speech_prob < 0.6` or `avg_logprob ≥ −1.0`
/// (loud and confident is real speech; the OpenAI/whisper.cpp rule needs both a high no-speech probability and a poor
/// logprob before it calls a segment silence). A segment without confidences is never dropped (Scribe, Apple, stubs).
/// The edge/silent/artifact guards stay as the second line. Counts only leave this type (`stt_dropped_segment_conf`).
public enum SegmentConfidence {
    public static let maxNoSpeechProb = 0.6
    public static let minAvgLogprob = -1.0
    public static let maxCompressionRatio = 2.4

    /// True when `segment` is dropped. `windows` are the chunk's 50 ms RMS windows (24 kHz frames).
    public static func drops(_ segment: EdgeSentenceGuard.Segment, windows: [Float]) -> Bool {
        let noSpeech = segment.noSpeechProb.map { $0 >= maxNoSpeechProb } ?? false
        let poorLogprob = segment.avgLogprob.map { $0 < minAvgLogprob } ?? false
        let loop = segment.compressionRatio.map { $0 > maxCompressionRatio } ?? false
        let loud = holdsSpeechWindow(segment, windows: windows)
        if loud && (!noSpeech || !poorLogprob) { return false }
        return noSpeech || (poorLogprob && !loud) || loop
    }

    /// Whether the segment's [start, end] holds a window ≥ −40 dBFS.
    static func holdsSpeechWindow(_ segment: EdgeSentenceGuard.Segment, windows: [Float]) -> Bool {
        guard !windows.isEmpty, segment.start.isFinite, segment.end.isFinite else { return false }
        let windowSeconds = Double(CaptureEvidence.windowFrames) / CaptureEvidence.rate
        let low = min(windows.count - 1, max(0, Int((segment.start / windowSeconds).rounded(.down))))
        let high = min(windows.count, max(low + 1, Int((segment.end / windowSeconds).rounded(.up))))
        return windows[low..<high].contains { $0 >= CaptureEvidence.speechRMS }
    }

    /// The chunk's text with dropped segments removed, the kept segments, and how many were dropped. Nothing changes
    /// when there are no segments, when no segment is dropped, or when the segments' letters are not the text's.
    public static func filter(text: String, segments: [EdgeSentenceGuard.Segment]?, windows: [Float])
        -> (text: String, segments: [EdgeSentenceGuard.Segment]?, dropped: Int) {
        guard let segments, !segments.isEmpty else { return (text, segments, 0) }
        func letters(_ s: String) -> [Character] { Array(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
        guard segments.flatMap({ letters($0.text) }) == letters(text) else { return (text, segments, 0) }
        let kept = segments.filter { !drops($0, windows: windows) }
        guard kept.count < segments.count else { return (text, segments, 0) }
        let joined = kept.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        return (joined, kept, segments.count - kept.count)
    }

    /// The trace's description: `[start-end p=… lp=… cr=… "text"(dropped), …]`, or `none`. Local trace only.
    public static func describe(_ segments: [EdgeSentenceGuard.Segment]?, windows: [Float]) -> String {
        guard let segments else { return "none" }
        func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
        return "[" + segments.map { segment in
            String(format: "%.2f-%.2f", segment.start, segment.end)
                + " p=\(number(segment.noSpeechProb)) lp=\(number(segment.avgLogprob)) cr=\(number(segment.compressionRatio))"
                + " \"\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))\""
                + (drops(segment, windows: windows) ? " dropped" : "")
        }.joined(separator: ", ") + "]"
    }
}
