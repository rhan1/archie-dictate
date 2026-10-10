import Foundation
import DictateObjC
@testable import DictateCore

final class RedTeamEngine: CaptureEngine {
    enum Fault { case none, swift, exception, tapException, missingBuiltIn }
    var faults: [Fault] = []
    var isAllocated = true
    var isRunning = false
    var taps = 0
    var attempts: [MicChoice] = []
    var rebuilds = 0
    var stopRaises = false
    var rebuildRaises = false
    var onStart: (() -> Void)?
    func start(device: MicChoice) throws {
        isAllocated = true
        attempts.append(device)
        taps += 1
        let fault = faults.isEmpty ? .none : faults.removeFirst()
        switch fault {
        case .none: isRunning = true
        case .swift: throw NSError(domain: "redteam.start", code: 7)
        case .missingBuiltIn: throw NSError(domain: "AudioDevices", code: 1)
        case .exception, .tapException:
            NSException(name: .internalInconsistencyException,
                        reason: fault == .tapException ? "installTap" : "start", userInfo: nil).raise()
        }
        onStart?()
    }
    func stop() -> [Float] {
        if stopRaises {
            stopRaises = false
            NSException(name: .internalInconsistencyException, reason: "stop/removeTap", userInfo: nil).raise()
        }
        isRunning = false
        taps = 0
        return []
    }
    func release() {
        // Release remains possible when stop/removeTap has poisoned an engine.
        isRunning = false; taps = 0; isAllocated = false
    }
    func rebuild() {
        release()
        rebuilds += 1
        if rebuildRaises {
            rebuildRaises = false
            NSException(name: .internalInconsistencyException, reason: "rebuild", userInfo: nil).raise()
        }
        _ = stop()
        isAllocated = true
    }
}

// No wall-clock sleep. Cancelled jobs can deliberately be delivered to model
// callbacks already queued when cancellation happened.
final class RedTeamClock: CaptureScheduler {
    final class Job: CaptureCancellation {
        let due: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(_ due: TimeInterval, _ action: @escaping () -> Void) { self.due = due; self.action = action }
        func cancel() { cancelled = true }
    }
    var now: TimeInterval = 0
    var jobs: [Job] = []
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CaptureCancellation {
        schedule(delay, action)
    }
    @discardableResult func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> Job {
        let job = Job(now + delay, action)
        jobs.append(job)
        return job
    }
    func advance(_ seconds: TimeInterval) {
        let target = now + seconds
        while let job = jobs.filter({ !$0.cancelled && $0.due <= target }).min(by: { $0.due < $1.due }) {
            jobs.removeAll { $0 === job }
            now = job.due
            job.action()
        }
        now = target
    }
}

func redTeamBoundary(_ action: () -> Void) -> NSError? {
    var error: NSError?
    _ = DictateTryObjC(action, &error)
    return error
}

func redTeamRig() -> (RedTeamEngine, CaptureLifecycle, RedTeamClock) {
    let engine = RedTeamEngine(), clock = RedTeamClock()
    let lifecycle = CaptureLifecycle(engine: engine, scheduler: clock)
    return (engine, lifecycle, clock)
}

/// D0b: AudioRecorder's bridge wiring on fakes — the default-input engine, a
/// built-in bridge engine on its own executor (watched for a wedge), and the
/// production CaptureFeed (arbitration + pre-roll ring). No audio hardware.
final class PreRollEngine: CaptureEngine {
    let headset = RedTeamEngine()
    private(set) var builtin = RedTeamEngine()
    private(set) var feed = CaptureFeed()
    private(set) var samples: [Float] = []
    private(set) var abandoned = 0
    private var builtinWatch = CaptureExecutorWatch()
    private let clock: RedTeamClock
    var defaultInput: CaptureBridge.DefaultInput = .bluetooth
    /// The bridge executor never returns from its current CoreAudio call (live 11:58Z).
    var builtinWedged = false
    init(clock: RedTeamClock) { self.clock = clock; headset.isAllocated = false; builtin.isAllocated = false }

    var isRunning: Bool { headset.isRunning }
    var isAllocated: Bool { headset.isAllocated || builtin.isAllocated }
    func start(device: MicChoice) throws {
        if isRunning { return }
        feed.start(defaultInput: device == .default ? defaultInput : .other, hasBuiltin: true)
        if feed.bridge.state == .builtinOnly {
            builtinWatch.began(at: clock.now)
            try builtin.start(device: .builtIn)
            if !builtinWedged { builtinWatch.ended() }
        }
        try headset.start(device: device)
    }
    func resetCapture(at time: TimeInterval) { samples = feed.recordingStarted(at: time) }
    func deliver(_ source: CaptureBridge.Source, at time: TimeInterval, frames: [Float], arrivedAt: TimeInterval? = nil) {
        let out = feed.accept(frames, source: source, at: time, arrivedAt: arrivedAt)
        samples += out.frames
        if out.releaseBuiltin { releaseBuiltin() }
    }
    func stop() -> [Float] {
        let captured = samples
        samples = []
        feed.cancel()
        releaseBuiltin()
        _ = headset.stop()
        return captured
    }
    func release() { _ = stop(); headset.release() }
    func rebuild() { headset.rebuild() }
    private func releaseBuiltin() {
        guard builtinWedged else { builtin.release(); return }
        // The queued teardown lands behind (or is) the call that never returns.
        if builtinWatch.busySince == nil { builtinWatch.began(at: clock.now) }
        if builtinWatch.isWedged(at: clock.now) {
            builtin = RedTeamEngine(); builtin.isAllocated = false
            builtinWatch = CaptureExecutorWatch(); builtinWedged = false; abandoned += 1
        }
    }
}
