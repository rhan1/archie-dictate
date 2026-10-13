import Foundation

/// v1.12 (L1): which source carried every kept frame, by sample time. `CaptureFeed` stamps each
/// kept batch with its source and host-clock start time; consecutive batches of one source
/// within `joinGap` form one run. This is the source of truth for the session line's
/// `carrier=builtin:0-1106,headset:1106-15110 headset_carried_ms=14004` (ms from the
/// recording boundary): the R4 misreading (`bridge_src=builtin` after a headset takeover) cannot
/// recur because the carrier is read from the frames, not from a state label.
///
/// Counts only — never audio. At most `maxRuns` runs are listed; past that the runs stop being
/// listed (`carrier_truncated=1`, the list ends `,+N`) but the per-source totals stay exact —
/// missing time is never turned into coverage by extending a run.
public struct SourceTimeline: Equatable, Sendable {
    public struct Run: Equatable, Sendable {
        public var source: CaptureBridge.Source
        /// Sample time of the run's first and last-plus-one frame (host-clock seconds).
        public var start: TimeInterval
        public var end: TimeInterval
        public var frames: Int
    }
    public static let rate = 24_000.0
    /// A pause shorter than this inside one source's frames does not split its run.
    public static let joinGap: TimeInterval = 0.05
    public static let maxRuns = 32

    public private(set) var boundary: TimeInterval?
    public private(set) var runs: [Run] = []
    public private(set) var unlistedRuns = 0
    public private(set) var builtinFrames = 0
    public private(set) var headsetFrames = 0
    private var last: Run?
    /// Source changes only (gaps inside one source are not changes): v1.11's `carrier=` intervals.
    public struct Change: Equatable, Sendable { public var source: CaptureBridge.Source; public var at: TimeInterval }
    public private(set) var changes: [Change] = []
    public static let maxChanges = 64
    /// v1.11's label for the headset source: `headset` on a Bluetooth default input, else `default_input`.
    public var headsetLabel = "headset"

    public init() {}

    public mutating func start(at boundary: TimeInterval) {
        let label = headsetLabel
        self = SourceTimeline()
        self.boundary = boundary
        headsetLabel = label
    }

    /// A kept batch: `count` frames of `source` whose first sample is at host time `time`.
    public mutating func append(_ source: CaptureBridge.Source, frames count: Int, at time: TimeInterval) {
        guard count > 0, boundary != nil else { return }
        if source == .builtin { builtinFrames += count } else { headsetFrames += count }
        let end = time + Double(count) / Self.rate
        if changes.last?.source != source, changes.count < Self.maxChanges { changes.append(Change(source: source, at: time)) }
        if var current = last, current.source == source, time - current.end < Self.joinGap {
            current.end = max(current.end, end)
            current.frames += count
            last = current
            if unlistedRuns == 0 { runs[runs.count - 1] = current }
            return
        }
        let run = Run(source: source, start: time, end: end, frames: count)
        last = run
        if runs.count < Self.maxRuns, unlistedRuns == 0 { runs.append(run) } else { unlistedRuns += 1 }
    }

    public var truncated: Bool { unlistedRuns > 0 }

    /// Frames each source carried, as ms of audio (exact, also when truncated).
    public var headsetCarriedMs: Int { Int((Double(headsetFrames) / Self.rate * 1000).rounded()) }
    public var builtinCarriedMs: Int { Int((Double(builtinFrames) / Self.rate * 1000).rounded()) }

    /// The source whose frames came last (nil: none kept).
    public var lastSource: CaptureBridge.Source? { last?.source }

    /// `carrier=builtin:0-1106,headset:1106-15110` (`carrier=none` when nothing was kept).
    public var carrierNote: String {
        guard let boundary, !runs.isEmpty else { return "carrier=none" }
        func ms(_ t: TimeInterval) -> Int { max(0, Int(((t - boundary) * 1000).rounded())) }   // pre-roll = 0, as capture_intervals
        let list = runs.map { "\($0.source == .builtin ? "builtin" : "headset"):\(ms($0.start))-\(ms($0.end))" }
        return "carrier=" + list.joined(separator: ",") + (truncated ? ",+\(unlistedRuns)" : "")
    }

    private func label(_ source: CaptureBridge.Source) -> String { source == .builtin ? "builtin" : headsetLabel }
    private func ms(_ t: TimeInterval) -> Int { max(0, Int(((t - (boundary ?? t)) * 1000).rounded())) }

    /// v1.11's `carrier=` value from the frames: `builtin:0-1100,headset:1100-15110` — each source
    /// from the sample time its first kept frame took over, the last one to `endMs` (recording end).
    public func carrierIntervals(endMs: Int) -> String {
        guard boundary != nil, !changes.isEmpty else { return "none" }
        return changes.enumerated().map { index, change in
            let start = index == 0 ? 0 : ms(change.at)
            let end = index + 1 < changes.count ? ms(changes[index + 1].at) : max(start, endMs)
            return "\(label(change.source)):\(start)-\(end)"
        }.joined(separator: ",")
    }

    /// v1.11's `headset_carried_ms=`: the ms of the headset's intervals in `carrierIntervals`.
    public func headsetIntervalMs(endMs: Int) -> Int {
        guard boundary != nil else { return 0 }
        return changes.enumerated().reduce(0) { total, item in
            guard item.element.source == .headset else { return total }
            let start = item.offset == 0 ? 0 : ms(item.element.at)
            let end = item.offset + 1 < changes.count ? ms(changes[item.offset + 1].at) : max(start, endMs)
            return total + max(0, end - start)
        }
    }

    /// v1.12: the exact runs, gaps shown: `carrier_frames=builtin:0-1100,headset:1100-15106`
    /// (+ ` carrier_frames_truncated=1`).
    public var framesNote: String {
        let runs = carrierNote.replacingOccurrences(of: "carrier=", with: "carrier_frames=")
            .replacingOccurrences(of: "headset:", with: "\(headsetLabel):")
        return runs + (truncated ? " carrier_frames_truncated=1" : "")
    }

    /// `carrier=… headset_carried_ms=N` (+ ` carrier_truncated=1`).
    public var note: String {
        "\(carrierNote) headset_carried_ms=\(headsetCarriedMs)" + (truncated ? " carrier_truncated=1" : "")
    }
}
