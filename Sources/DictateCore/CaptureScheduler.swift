import Foundation

public protocol CaptureCancellation: AnyObject { func cancel() }
public protocol CaptureScheduler: AnyObject {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CaptureCancellation
}

/// Production deadlines and recovery waits share the main event queue.
public final class CaptureDispatchScheduler: CaptureScheduler {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private final class Cancellation: CaptureCancellation {
        let work: DispatchWorkItem
        init(_ work: DispatchWorkItem) { self.work = work }
        func cancel() { work.cancel() }
    }
    public func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CaptureCancellation {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return Cancellation(work)
    }
    @MainActor public func wait(_ delay: TimeInterval) async {
        await withCheckedContinuation { continuation in
            _ = schedule(after: delay) { continuation.resume() }
        }
    }
}

/// Identity tokens do not wrap and cannot match a callback from an older session.
public final class CaptureEpoch {
    public init() {}
}
