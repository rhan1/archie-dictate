import Foundation

/// v1.9 L3: what the dictation actually kept, as counts only — the sample-time
/// intervals of kept frames (ms from the recording boundary, written at session end as
/// `capture_intervals=`) and the number of speech sections (`speech_sections=`). No audio is
/// retained here: frames are folded into 50 ms RMS windows as they pass. Speech is measured
/// relative to the dictation's own noise floor: R1's built-in fallback peaked at −24.8 dBFS
/// but its speech windows were below the former fixed −40 dBFS RMS threshold.
///
/// v1.10 L2: the relative rule follows the dictation's own contrast. 10-13 07:00–07:10 the
/// built-in at headset distance read `speech_sections=0` on 5 of 6 fallback runs (R3
/// `peak_dbfs=-28.4`): its loudest speech windows sit ~9 dB over its room floor, under v1.9's
/// fixed +12 dB. A window is speech when it is above −40 dBFS (unchanged) or, when the
/// dictation's 95th-percentile window is ≥ `minContrastDB` over its 10th-percentile floor, when it
/// is ≥ max(`minContrastDB`, half that contrast) over the floor (and above −60 dBFS). Constant
/// noise has no contrast and never counts; digital zeros never set the floor.
public struct CaptureEvidence: Sendable {
    public static let rate = 24_000.0
    /// RMS window for speech detection.
    public static let windowFrames = 1_200
    /// −40 dBFS.
    public static let speechRMS: Float = 0.01
    /// −60 dBFS: digital zeros and near-zeros are never speech.
    public static let quietSpeechFloor: Float = 0.001
    /// v1.10: the least contrast (95th vs 10th percentile window) that can hold speech, and the
    /// least margin over the floor a speech window needs.
    public static let minContrastDB: Float = 6
    /// Windows below this are digital silence: never part of the floor (a dropped link's zeros).
    public static let digitalSilenceRMS: Float = 0.00001
    public static let minSection: TimeInterval = 0.3
    public static let minSeparation: TimeInterval = 0.2
    /// Abutting buffers whose timestamps jitter by up to this much stay one interval.
    public static let mergeTolerance: TimeInterval = 0.025
    public static let maxIntervals = 400
    /// Ten minutes of 50 ms RMS windows; no samples or audio are retained.
    public static let maxRecordedWindows = 12_000

    public private(set) var origin: TimeInterval?
    /// [start, end) in seconds from `origin`, in the order frames were kept.
    public private(set) var intervals: [(start: Double, end: Double)] = []
    public private(set) var truncated = false
    public private(set) var framesKept = 0
    /// Completed sections so far. The open section, if any, is included by `finalSpeechSections`.
    public var speechSections: Int { activeDetector.speechSections }
    private var windowSum: Double = 0
    private var windowCount = 0
    /// A counts-only level envelope, capped so a long dictation has a fixed memory cost.
    private var recordedWindows: [Float] = []
    /// Once the envelope is full, this continues under the unchanged absolute threshold only.
    private var absoluteTailDetector: SectionDetector?

    public init() {}

    public mutating func start(at boundary: TimeInterval) {
        self = CaptureEvidence()
        origin = boundary
    }

    /// Frames that entered the dictation, starting at host time `time`.
    public mutating func append(_ frames: ArraySlice<Float>, at time: TimeInterval) {
        guard let origin, !frames.isEmpty else { return }
        framesKept += frames.count
        let start = max(0, time - origin)
        let end = max(start, time - origin + Double(frames.count) / Self.rate)
        if let last = intervals.last, start >= last.end - 0.001, start <= last.end + Self.mergeTolerance {
            intervals[intervals.count - 1].end = max(last.end, end)
        } else if intervals.count < Self.maxIntervals {
            intervals.append((start, end))
        } else {
            truncated = true
            intervals[intervals.count - 1].end = max(intervals[intervals.count - 1].end, end)
        }
        for sample in frames {
            windowSum += Double(sample * sample)
            windowCount += 1
            if windowCount == Self.windowFrames { closeWindow() }
        }
    }
    public mutating func append(_ frames: [Float], at time: TimeInterval) { append(frames[...], at: time) }

    private mutating func closeWindow() {
        let rms = Float((windowSum / Double(windowCount)).squareRoot())
        windowSum = 0
        windowCount = 0
        if recordedWindows.count < Self.maxRecordedWindows {
            recordedWindows.append(rms)
        } else {
            if absoluteTailDetector == nil {
                absoluteTailDetector = detector(for: recordedWindows)
            }
            absoluteTailDetector?.append(loud: rms >= Self.speechRMS)
        }
    }

    private var activeDetector: SectionDetector {
        absoluteTailDetector ?? detector(for: recordedWindows)
    }

    private func detector(for windows: [Float]) -> SectionDetector {
        var detector = SectionDetector()
        for loud in Self.speechWindows(windows) { detector.append(loud: loud) }
        return detector
    }

    /// Which of `windows` (50 ms RMS, one dictation or one chunk) are speech. Shared with
    /// `LowSpeechSentenceGuard` so a chunk's speech ratio uses the same rule.
    public static func speechWindows(_ windows: [Float]) -> [Bool] {
        let threshold = relativeThreshold(windows)
        return windows.map { rms in
            rms >= speechRMS || (rms >= quietSpeechFloor && threshold.map { rms >= $0 } ?? false)
        }
    }

    /// v1.11 L1: windows that MAY hold speech — above −40 dBFS, or `minContrastDB` over the floor of
    /// `reference` (the whole dictation so far; never the chunk alone, whose own contrast a key
    /// click supplies). Deleting text needs the absence of even this; soft words veto a drop.
    public static func possibleSpeechWindows(_ windows: [Float], reference: [Float]) -> [Bool] {
        let audible = reference.filter { $0 >= digitalSilenceRMS }.sorted()
        let floor = audible.isEmpty ? nil : audible[Int((Double(audible.count - 1) * 0.1).rounded(.down))]
        let threshold = floor.map { $0 * pow(10, minContrastDB / 20) }
        return windows.map { rms in
            rms >= speechRMS || (rms >= quietSpeechFloor && threshold.map { rms >= $0 } ?? false)
        }
    }

    /// The relative speech threshold, or nil when the windows hold no contrast.
    static func relativeThreshold(_ windows: [Float]) -> Float? {
        let audible = windows.filter { $0 >= digitalSilenceRMS }.sorted()
        guard audible.count >= 2 else { return nil }
        let floor = audible[Int((Double(audible.count - 1) * 0.1).rounded(.down))]
        let top = audible[Int((Double(audible.count - 1) * 0.95).rounded(.down))]
        let contrast = 20 * log10(top / floor)
        guard contrast >= minContrastDB else { return nil }
        return floor * pow(10, max(minContrastDB, contrast / 2) / 20)
    }

    /// The 50 ms RMS series the speech rule judged (counts-only levels, never written anywhere;
    /// capped at `maxRecordedWindows`). Tests replay it against the frames the transcriber got.
    public var levelEnvelope: [Float] { recordedWindows }

    /// Sections including the one still open (the recording may end mid-word).
    public var finalSpeechSections: Int {
        activeDetector.finalSpeechSections
    }

    /// `0-1200,1300-33900` (ms), or `none`.
    public var intervalsNote: String {
        guard !intervals.isEmpty else { return "none" }
        return intervals.map { "\(Int(($0.start * 1000).rounded()))-\(Int(($0.end * 1000).rounded()))" }
            .joined(separator: ",")
    }

    private struct SectionDetector: Sendable {
        var speechSections = 0
        private var sectionSpan = 0      // windows from the first loud window to the last
        private var quietRun = 0
        private var inSection = false

        mutating func append(loud: Bool) {
            if loud {
                if !inSection { inSection = true; sectionSpan = 0; quietRun = 0 }
                sectionSpan += quietRun + 1
                quietRun = 0
            } else if inSection {
                quietRun += 1
                if quietRun >= Self.separation { closeSection() }
            }
        }

        var finalSpeechSections: Int {
            var copy = self
            if copy.inSection { copy.closeSection() }
            return copy.speechSections
        }

        private static let separation = Int((CaptureEvidence.minSeparation /
            (Double(CaptureEvidence.windowFrames) / CaptureEvidence.rate)).rounded(.up))

        private mutating func closeSection() {
            let windowSeconds = Double(CaptureEvidence.windowFrames) / CaptureEvidence.rate
            if Double(sectionSpan) * windowSeconds >= CaptureEvidence.minSection - 0.000001 {
                speechSections += 1
            }
            inSection = false
            sectionSpan = 0
            quietRun = 0
        }
    }
}

/// v1.8 (GPT-6 B1): PCM chunks leave the recorder's state lock in sequence order. The owner
/// enqueues under its lock (a cheap append) and drains after unlocking; a callback that
/// re-enters the recorder (reads state, calls `stop()`) never deadlocks, and concurrent
/// drains deliver strictly in sequence.
public final class OrderedDelivery<Item>: @unchecked Sendable {
    private let queueLock = NSLock()
    private let deliverLock = NSRecursiveLock()
    private var queue: [(sequence: UInt64, item: Item, callback: (Item) -> Void)] = []
    private var nextSequence: UInt64 = 0
    public private(set) var lastDelivered: UInt64?

    public init() {}

    /// Assigns the next sequence number. Safe to call while holding the owner's lock.
    @discardableResult
    public func enqueue(_ item: Item, to callback: @escaping (Item) -> Void) -> UInt64 {
        queueLock.withLock {
            nextSequence += 1
            queue.append((nextSequence, item, callback))
            return nextSequence
        }
    }

    /// Never call while holding the owner's state lock.
    public func drain() {
        deliverLock.lock()
        defer { deliverLock.unlock() }
        while let next = queueLock.withLock({ queue.isEmpty ? nil : queue.removeFirst() }) {
            queueLock.withLock { lastDelivered = next.sequence }
            next.callback(next.item)
        }
    }

    /// Drops everything not yet delivered (a cancelled dictation).
    public func discardPending() { queueLock.withLock { queue.removeAll() } }
    public var pendingCount: Int { queueLock.withLock { queue.count } }
}
