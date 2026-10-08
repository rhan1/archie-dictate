import Foundation
import DictateObjC
@testable import DictateCore

final class RedTeamEngine: CaptureEngine {
    enum Fault { case none, swift, exception, tapException, missingBuiltIn }
    var faults: [Fault] = []
    var isRunning = false
    var taps = 0
    var attempts: [MicChoice] = []
    var rebuilds = 0
    var stopRaises = false
    var rebuildRaises = false
    var onStart: (() -> Void)?
    func start(device: MicChoice) throws {
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
    func rebuild() {
        rebuilds += 1
        if rebuildRaises {
            rebuildRaises = false
            NSException(name: .internalInconsistencyException, reason: "rebuild", userInfo: nil).raise()
        }
        _ = stop()
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
