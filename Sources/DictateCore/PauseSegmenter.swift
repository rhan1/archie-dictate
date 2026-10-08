import Foundation

/// Decides when to commit a Realtime segment: after a natural pause (enough
/// quiet chunks in a row) once enough audio has piled up since the last commit.
/// Never splits mid-word because it only commits on silence.
public struct PauseSegmenter: Sendable {
    public static let sampleRate = 24_000
    /// RMS below this (−40 dBFS) counts as quiet.
    public static let quietRMS: Float = 0.01
    public static let minQuietSeconds = 0.2
    public static let minSegmentSeconds = 1.0
    /// Long fluent speech (measured live: 3 segments in 15 s through a headset
    /// whose noise floor sits above −40 dBFS) left a 1.1 s final transcription.
    /// After this much uncommitted audio a 100 ms dip is enough to commit.
    public static let longSegmentSeconds = 3.0
    /// A chunk 12 dB under the running speech level also counts as quiet.
    public static let relativeQuiet: Float = 0.25

    public let enabled: Bool
    private var uncommitted = 0
    private var quietRun = 0
    private var heardSpeech = false
    private var speechLevel: Float = 0

    public init(enabled: Bool = true) { self.enabled = enabled }

    /// True when speech since the last commit is still uncommitted (at least
    /// 100 ms of audio — the API rejects smaller commits). A quiet-only tail is
    /// never worth committing: it costs a round-trip and the model may invent
    /// text for silence.
    public var hasUncommittedSpeech: Bool { heardSpeech && uncommitted >= Self.sampleRate / 10 }

    /// Feed each appended chunk; returns true when a commit should follow it.
    public mutating func shouldCommit(after samples: [Int16]) -> Bool {
        uncommitted += samples.count
        let rms = Self.rms(samples)
        let quiet = rms < Self.quietRMS || (speechLevel > 0 && rms < speechLevel * Self.relativeQuiet)
        if quiet {
            quietRun += samples.count
        } else {
            quietRun = 0
            heardSpeech = true
            speechLevel = speechLevel == 0 ? rms : speechLevel * 0.9 + rms * 0.1
        }
        let long = uncommitted >= Int(Self.longSegmentSeconds * Double(Self.sampleRate))
        let neededQuiet = long ? Self.sampleRate / 10 : Int(Self.minQuietSeconds * Double(Self.sampleRate))
        guard enabled, heardSpeech, quietRun >= neededQuiet,
              uncommitted >= Int(Self.minSegmentSeconds * Double(Self.sampleRate)) else { return false }
        markCommitted()
        return true
    }

    public mutating func markCommitted() {
        uncommitted = 0
        quietRun = 0
        heardSpeech = false
    }

    static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float(sqrt(sum / Double(samples.count)) / 32_768)
    }
}
