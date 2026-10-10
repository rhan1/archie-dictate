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

/// The operation currently running on a recorder's serial executor. One that has
/// not returned after `wedgeSeconds` (a CoreAudio call that never comes back)
/// lets the owner abandon that executor rather than queue every later start and
/// teardown behind it (D-b). The owner serializes access.
public struct CaptureExecutorWatch: Sendable {
    /// The bridge's built-in start is ~0.1 s; its teardown is milliseconds.
    public static let wedgeSeconds: TimeInterval = 1.5
    public private(set) var busySince: TimeInterval?
    public init() {}
    public mutating func began(at time: TimeInterval) { busySince = time }
    public mutating func ended() { busySince = nil }
    public func isWedged(at now: TimeInterval) -> Bool {
        busySince.map { now - $0 >= Self.wedgeSeconds } ?? false
    }
}
