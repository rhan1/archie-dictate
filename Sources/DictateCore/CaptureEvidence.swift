import Foundation

/// v1.8 (L4 input): what the dictation actually kept, as counts only — the sample-time
/// intervals of kept frames (ms from the recording boundary, written at session end as
/// `capture_intervals=`) and the number of speech sections (`speech_sections=`). No audio is
/// retained here: frames are folded into 50 ms RMS windows as they pass.
public struct CaptureEvidence: Sendable {
    public static let rate = 24_000.0
    /// RMS window for speech detection.
    public static let windowFrames = 1_200
    /// −40 dBFS.
    public static let speechRMS: Float = 0.01
    public static let minSection: TimeInterval = 0.3
    public static let minSeparation: TimeInterval = 0.2
    /// Abutting buffers whose timestamps jitter by up to this much stay one interval.
    public static let mergeTolerance: TimeInterval = 0.025
    public static let maxIntervals = 400

    public private(set) var origin: TimeInterval?
    /// [start, end) in seconds from `origin`, in the order frames were kept.
    public private(set) var intervals: [(start: Double, end: Double)] = []
    public private(set) var truncated = false
    public private(set) var framesKept = 0
    public private(set) var speechSections = 0
    private var windowSum: Double = 0
    private var windowCount = 0
    private var loudWindows = 0      // loud windows in the open section
    private var sectionSpan = 0      // windows from the section's first loud window to its last
    private var quietRun = 0
    private var inSection = false

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
        let windowSeconds = Double(Self.windowFrames) / Self.rate
        let separation = Int((Self.minSeparation / windowSeconds).rounded(.up))
        if rms >= Self.speechRMS {
            if !inSection { inSection = true; loudWindows = 0; sectionSpan = 0; quietRun = 0 }
            sectionSpan += quietRun + 1
            quietRun = 0
            loudWindows += 1
        } else if inSection {
            quietRun += 1
            if quietRun >= separation { closeSection() }
        }
    }

    private mutating func closeSection() {
        let windowSeconds = Double(Self.windowFrames) / Self.rate
        if Double(sectionSpan) * windowSeconds >= Self.minSection - 0.000001 { speechSections += 1 }
        inSection = false
        sectionSpan = 0
        loudWindows = 0
        quietRun = 0
    }

    /// Sections including the one still open (the recording may end mid-word).
    public var finalSpeechSections: Int {
        var copy = self
        if copy.inSection { copy.closeSection() }
        return copy.speechSections
    }

    /// `0-1200,1300-33900` (ms), or `none`.
    public var intervalsNote: String {
        guard !intervals.isEmpty else { return "none" }
        return intervals.map { "\(Int(($0.start * 1000).rounded()))-\(Int(($0.end * 1000).rounded()))" }
            .joined(separator: ",")
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
