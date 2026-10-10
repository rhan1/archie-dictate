import Foundation

/// Bounded pre-roll store for 24 kHz mono frames that arrive between the first
/// ⌥ tap and the recording boundary (host-clock timestamps). The oldest frames
/// are overwritten; nothing here ever leaves memory.
public struct CaptureRing {
    public static let sampleRate: Double = 24_000
    /// Audio kept from before the second tap.
    public static let preRoll: TimeInterval = 0.15
    /// 1.0 s at the pipeline rate: longer than the 0.7 s double-tap window.
    public static let defaultCapacity = 24_000
    public let capacity: Int
    public private(set) var count = 0
    private var storage: [Float]
    private var head = 0
    // Contiguous runs, oldest first: a gap or a source handover keeps its own timestamp.
    private struct Run { var time: TimeInterval; var count: Int }
    private var runs: [Run] = []

    public init(capacity: Int = CaptureRing.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    /// Host time of the oldest stored frame.
    public var oldestTime: TimeInterval? { runs.first?.time }
    /// Host time just past the newest stored frame.
    public var newestEnd: TimeInterval? { runs.last.map { $0.time + Double($0.count) / Self.sampleRate } }

    public mutating func append(_ frames: [Float], at time: TimeInterval) {
        guard !frames.isEmpty else { return }
        let skip = max(0, frames.count - capacity)
        let time = time + Double(skip) / Self.sampleRate
        let incoming = frames.count - skip
        if count + incoming > capacity { dropOldest(count + incoming - capacity) }
        var index = (head + count) % capacity
        for frame in frames[skip...] {
            storage[index] = frame
            index = index + 1 == capacity ? 0 : index + 1
        }
        if let last = runs.last,
           abs(last.time + Double(last.count) / Self.sampleRate - time) < 0.5 / Self.sampleRate {
            runs[runs.count - 1].count += incoming
        } else {
            runs.append(Run(time: time, count: incoming))
        }
        count += incoming
    }

    /// Every stored frame captured at or after `time`, oldest first; empties the ring.
    public mutating func drain(from time: TimeInterval) -> [Float] {
        var kept: [Float] = []
        var offset = 0
        for run in runs {
            let skip = min(run.count, max(0, Int(ceil((time - run.time) * Self.sampleRate - 0.000001))))
            for i in (offset + skip)..<(offset + run.count) { kept.append(storage[(head + i) % capacity]) }
            offset += run.count
        }
        removeAll()
        return kept
    }

    public mutating func removeAll() {
        head = 0
        count = 0
        runs.removeAll()
    }

    private mutating func dropOldest(_ frames: Int) {
        var remaining = min(frames, count)
        head = (head + remaining) % capacity
        count -= remaining
        while remaining > 0, !runs.isEmpty {
            if runs[0].count <= remaining {
                remaining -= runs[0].count
                runs.removeFirst()
            } else {
                runs[0].count -= remaining
                runs[0].time += Double(remaining) / Self.sampleRate
                remaining = 0
            }
        }
    }
}

/// The recorder's single serialized path for converted frames: source
/// arbitration (CaptureBridge), the pre-roll ring before the second tap, and the
/// frames that enter the dictation after it. The owner holds its lock around
/// every call, exactly as it did for the bridge alone.
public struct CaptureFeed {
    public struct Output: Equatable, Sendable {
        public var frames: [Float] = []
        public var releaseBuiltin = false
        /// These are the first kept frames after the second tap (cold start).
        public var firstKept = false
        public var restartHeadset = false
        public var event: CaptureBridge.Event?
    }
    public private(set) var bridge = CaptureBridge()
    public private(set) var ring: CaptureRing
    /// While the headset carries, the built-in's latest frames wait here so a switchback
    /// resumes exactly where the headset stopped (the buffer that crossed the switch
    /// arrived before the decision). 1.5 s covers the stale-headset wait (1.0 s) plus one buffer.
    private var standby = CaptureRing(capacity: 36_000)

    public init(ringCapacity: Int = CaptureRing.defaultCapacity) {
        ring = CaptureRing(capacity: ringCapacity)
    }

    public mutating func start(defaultInput: CaptureBridge.DefaultInput, hasBuiltin: Bool,
                               epoch: CaptureEpoch = CaptureEpoch()) {
        bridge.start(defaultInput: defaultInput, hasBuiltin: hasBuiltin, epoch: epoch)
        ring.removeAll()
        standby.removeAll()
    }

    public mutating func accept(_ frames: [Float], source: CaptureBridge.Source, at time: TimeInterval,
                                arrivedAt: TimeInterval? = nil, epoch: CaptureEpoch? = nil) -> Output {
        let hadKept = bridge.firstKeptMs != nil
        let peak = frames.reduce(Float(0)) { max($0, abs($1)) }
        let decision = bridge.buffer(source: source, at: time, frames: frames.count,
                                     arrivedAt: arrivedAt, epoch: epoch, peak: peak)
        var output = Output(releaseBuiltin: decision.releaseBuiltin,
                            restartHeadset: decision.restartHeadset, event: decision.event)
        let trimmed = frames.dropFirst(decision.dropFrames)
        if decision.framesToRing > 0 {
            ring.append(Array(trimmed.prefix(decision.framesToRing)),
                        at: time + Double(decision.dropFrames) / CaptureRing.sampleRate)
        }
        output.frames = Array(trimmed.prefix(decision.framesToFeed))
        if source == .builtin, bridge.canSwitchBack || decision.event == .switchback {
            standby.append(frames, at: time)
        }
        if decision.event == .switchback { output.frames += resumeBuiltin() }
        output.firstKept = !hadKept && bridge.firstKeptMs != nil
        return output
    }

    /// The standby built-in frames from where the headset stopped (into the ring before the second tap).
    private mutating func resumeBuiltin() -> [Float] {
        let end = standby.newestEnd
        let resumed = standby.drain(from: bridge.fedThroughTime ?? 0)
        guard let end, !resumed.isEmpty else { return [] }
        bridge.resumedBuiltin(frames: resumed.count, through: end)
        if bridge.isRecording { return resumed }
        ring.append(resumed, at: end - Double(resumed.count) / CaptureRing.sampleRate)
        return []
    }

    /// The headset engine failed for good: the built-in carries on from where the headset
    /// stopped. Returns the event (nil: nothing carries) and the frames to append.
    public mutating func headsetFailed() -> (event: CaptureBridge.Event?, frames: [Float]) {
        let switching = bridge.state == .switched
        let event = bridge.headsetFailed()
        return (event, switching && event == .switchback ? resumeBuiltin() : [])
    }

    /// The second tap: keeps ring audio from `time − preRoll` and returns it.
    public mutating func recordingStarted(at time: TimeInterval,
                                          preRoll: TimeInterval = CaptureRing.preRoll) -> [Float] {
        let kept = ring.drain(from: time - preRoll)
        bridge.recordingStarted(at: time, preRoll: preRoll, keptFrames: kept.count)
        return kept
    }

    /// Lone tap, finish or cancel: the ring is discarded with the session.
    /// Returns true when the bridge still owned the built-in input.
    @discardableResult public mutating func cancel() -> Bool {
        ring.removeAll()
        standby.removeAll()
        return bridge.cancel()
    }

    public mutating func builtinFailed() { bridge.builtinFailed() }
    public mutating func headsetRestarted(started: Bool = true) { bridge.headsetRestarted(started: started) }
    public mutating func setHeadsetRecovering(_ recovering: Bool) { bridge.setHeadsetRecovering(recovering) }
}
