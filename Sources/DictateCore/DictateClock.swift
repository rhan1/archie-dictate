import Foundation

public protocol DictateClock: Sendable {
    func now() -> ContinuousClock.Instant
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

extension DictateClock {
    public func sleep(for duration: Duration) async throws {
        try await sleep(until: now().advanced(by: duration))
    }
}

public struct SystemClock: DictateClock {
    public init() {}
    public func now() -> ContinuousClock.Instant {
        ContinuousClock.now
    }
    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await ContinuousClock().sleep(until: deadline)
    }
}

public final class ManualClock: DictateClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let origin: ContinuousClock.Instant
    private var offset: Duration = .zero
    private var nextId: UInt64 = 0
    private var sleepersList: [Sleeper] = []
    private let lock = NSLock()

    public init() {
        self.origin = ContinuousClock.now
    }

    public func now() -> ContinuousClock.Instant {
        lock.withLock { origin.advanced(by: offset) }
    }

    public var elapsed: Duration {
        lock.withLock { offset }
    }

    public var sleepers: Int {
        lock.withLock { sleepersList.count }
    }

    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let id: UInt64 = lock.withLock {
            if deadline <= origin.advanced(by: offset) {
                return 0
            }
            nextId += 1
            return nextId
        }
        if id == 0 {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= origin.advanced(by: offset) {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepersList.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = sleepersList.firstIndex(where: { $0.id == id }) {
                let sleeper = sleepersList.remove(at: index)
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    public func advance(by duration: Duration) {
        let toResume: [Sleeper] = lock.withLock {
            offset += duration
            let currentNow = origin.advanced(by: offset)
            let ready = sleepersList
                .filter { $0.deadline <= currentNow }
                .sorted {
                    if $0.deadline != $1.deadline {
                        return $0.deadline < $1.deadline
                    }
                    return $0.id < $1.id
                }
            let readyIds = Set(ready.map(\.id))
            sleepersList.removeAll { readyIds.contains($0.id) }
            return ready
        }
        for sleeper in toResume {
            sleeper.continuation.resume()
        }
    }

    public func waitForSleepers(_ n: Int, timeout: Duration = .seconds(5)) async -> Bool {
        let start = ContinuousClock.now
        while sleepers < n {
            if start.duration(to: .now) >= timeout {
                return false
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}
