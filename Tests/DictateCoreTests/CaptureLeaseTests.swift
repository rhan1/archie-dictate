import Foundation
import Testing
@testable import DictateCore

/// v1.12 L1: one session-scoped capture lease (GPT-6 review §A, §F "Capture/lease", rank 4).
/// A manual clock and scheduler: nothing here waits on wall time.
@Suite("CaptureLease")
struct CaptureLeaseTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 0
        private var due: [(at: TimeInterval, work: @Sendable () -> Void)] = []
        var now: TimeInterval { lock.withLock { time } }
        func schedule(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
            lock.withLock { due.append((time + delay, work)) }
        }
        /// Advances to `t`, running every scheduled item due by then (in time order).
        func advance(to t: TimeInterval) {
            while true {
                let next: (at: TimeInterval, work: @Sendable () -> Void)? = lock.withLock {
                    guard let index = due.indices.filter({ due[$0].at <= t + 1e-9 }).min(by: { due[$0].at < due[$1].at }) else {
                        time = t
                        return nil
                    }
                    let item = due.remove(at: index)
                    time = item.at
                    return item
                }
                guard let next else { return }
                next.work()
            }
        }
    }
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }
    typealias Outcome = Result<CaptureLease, CaptureLeaseBroker.Refusal>

    static func broker(_ clock: Clock) -> CaptureLeaseBroker {
        CaptureLeaseBroker(clock: { clock.now }, schedule: { clock.schedule($0, $1) })
    }
    static func lease(_ outcome: Outcome?) -> CaptureLease? {
        if case .success(let lease)? = outcome { return lease }
        return nil
    }
    static func refusal(_ outcome: Outcome?) -> CaptureLeaseBroker.Refusal? {
        if case .failure(let refusal)? = outcome { return refusal }
        return nil
    }

    // MARK: The review's literal: "old release completes after new request"

    @Test func oldReleaseCompletesAfterNewRequestTheNewLeaseWaitsThenIsAdmittedOnce() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let old = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no first lease"); return }
        old.started(.builtin); old.started(.headset)
        old.release(at: 0)                                        // stop() returned; hardware still tearing down
        #expect(old.state == .releasing(since: 0))
        let results = Box<Outcome>()
        clock.advance(to: 0.010)
        broker.request(.conversation) { results.append($0) }      // ⌘⌘ right after ⌥⌥ ended
        #expect(results.all.isEmpty)                              // waits: never started on top of the old hardware
        clock.advance(to: 0.030)
        old.partReleased(.builtin)
        #expect(results.all.isEmpty)                              // the headset client is still releasing
        clock.advance(to: 0.050)
        old.partReleased(.headset)
        guard let new = Self.lease(results.all.first) else { Issue.record("not admitted"); return }
        #expect(results.all.count == 1)
        #expect(new.kind == .conversation && new.waitedMs == 40)
        #expect(old.state == .released && new.isActive)
        #expect(broker.granted == 2 && broker.releasesCompleted == 1)
        #expect(!new.admits(old.token) && !old.admits(old.token) && new.admits(new.token))
        clock.advance(to: 5)                                      // the waiter's expiry later finds nothing
        #expect(results.all.count == 1 && broker.holder === new)
    }

    @Test func alternatingOptionOptionCommandCommandRequestsAdmitOneOwner() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let dictation = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no lease"); return }
        // While live: every other request is refused, whatever its kind.
        #expect(Self.refusal(broker.tryAcquire(.conversation)) == .busy(holder: .dictation))
        #expect(Self.refusal(broker.tryAcquire(.dictation)) == .busy(holder: .dictation))
        dictation.started(.headset)
        dictation.release(at: 0)
        let results = Box<(String, Outcome)>()
        for (index, kind) in [CaptureLeaseBroker.Kind.conversation, .dictation, .conversation, .dictation].enumerated() {
            clock.advance(to: 0.01 * Double(index + 1))
            broker.request(kind) { results.append(("\(index):\(kind.rawValue)", $0)) }
        }
        #expect(results.all.isEmpty)
        clock.advance(to: 0.1)
        dictation.partReleased(.headset)
        let admitted = results.all.filter { if case .success = $0.1 { return true } else { return false } }
        #expect(admitted.map(\.0) == ["0:conversation"])          // exactly one owner, the first waiter
        #expect(results.all.count == 4)
        #expect(results.all.dropFirst().allSatisfy { Self.refusal($0.1) == .busy(holder: .conversation) })
        #expect(broker.granted == 2)
    }

    @Test func aWaiterThatOutlivesTheWaitIsRefusedReleasePending() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let old = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no lease"); return }
        old.started(.builtin)
        old.release(at: 0)
        let results = Box<Outcome>()
        broker.request(.dictation, wait: 1.0) { results.append($0) }
        clock.advance(to: 0.99)
        #expect(results.all.isEmpty)
        clock.advance(to: 1.0)
        #expect(Self.refusal(results.all.first) == .releasePending(holder: .dictation))
        #expect(CaptureLeaseBroker.Refusal.releasePending(holder: .dictation).note == "lease_refused=release_pending holder=dictation")
    }

    @Test func aReleaseThatNeverCompletesIsQuarantinedNeverReused() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let stuck = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no lease"); return }
        stuck.started(.builtin)
        let settled = Box<CaptureLease.State>()
        stuck.whenSettled { settled.append($0) }
        stuck.release(at: 0)                                      // the built-in queue is wedged: no ack ever
        clock.advance(to: CaptureLeaseBroker.quarantineAfter)
        guard let next = Self.lease(broker.tryAcquire(.conversation)) else { Issue.record("blocked behind a wedged release"); return }
        #expect(stuck.state == .quarantined && settled.all == [.quarantined])
        #expect(next.afterQuarantine && next.grantNote == "lease=2 lease_kind=conversation lease_wait_ms=0 quarantined_prev=1")
        stuck.partReleased(.builtin)                              // the wedged call returns much later
        #expect(stuck.state == .quarantined && broker.holder === next && next.isActive)
        #expect(!next.admits(stuck.token) && broker.quarantined == 1)
    }

    @Test func aWaiterIsAdmittedWhenTheStuckReleaseIsQuarantined() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let stuck = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no lease"); return }
        stuck.started(.headset)
        stuck.release(at: 0)
        clock.advance(to: 3.0)
        let results = Box<Outcome>()
        broker.request(.dictation) { results.append($0) }         // waits ≤ 2 s; quarantine due at 4 s
        clock.advance(to: 4.0)
        guard let lease = Self.lease(results.all.first) else { Issue.record("not admitted at quarantine"); return }
        #expect(lease.afterQuarantine && lease.waitedMs == 1000)
    }

    @Test func noPartsStartedReleasesAtOnce() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let lease = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no lease"); return }
        lease.release()
        #expect(lease.state == .released && broker.holder == nil)
        #expect(lease.note == "lease=1 lease_kind=dictation lease_wait_ms=0 release_ms=0")
        #expect(!lease.started(.headset))                         // a dead lease starts no hardware
        #expect(Self.lease(broker.tryAcquire(.conversation)) != nil)
    }

    @Test func releaseMsIsMeasuredToTheLastAcknowledgement() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let lease = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no lease"); return }
        lease.started(.builtin); lease.started(.headset)
        clock.advance(to: 10)
        lease.release()
        clock.advance(to: 10.012); lease.partReleased(.headset)
        #expect(lease.pendingParts == [.builtin])
        clock.advance(to: 10.041); lease.partReleased(.builtin)
        #expect(lease.note == "lease=1 lease_kind=dictation lease_wait_ms=0 release_ms=41")
    }

    @Test func onlyTheActiveLeaseOwnsTheMute() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let first = Self.lease(broker.tryAcquire(.conversation)) else { Issue.record("no lease"); return }
        #expect(first.claimMute() && first.ownsMute)
        first.release()
        #expect(!first.ownsMute && !first.claimMute())
        guard let second = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no lease"); return }
        #expect(second.claimMute() && !first.ownsMute)
    }

    // MARK: Per-callback lease identity reaches the frame path

    @Test func aLateCallbackOfTheOldLeaseCannotAppendToTheNewSession() {
        let clock = Clock()
        let broker = Self.broker(clock)
        guard let old = Self.lease(broker.tryAcquire(.dictation)) else { Issue.record("no lease"); return }
        old.release()
        guard let new = Self.lease(broker.tryAcquire(.conversation)) else { Issue.record("no lease"); return }
        var feed = CaptureFeed()
        feed.start(defaultInput: .other, hasBuiltin: false, epoch: new.token)
        _ = feed.recordingStarted(at: 1.0, preRoll: 0)
        let late = feed.accept([Float](repeating: 0.5, count: 2_400), source: .headset, at: 1.0, epoch: old.token)
        let own = feed.accept([Float](repeating: 0.25, count: 2_400), source: .headset, at: 1.0, epoch: new.token)
        #expect(late.frames.isEmpty && own.frames.count == 2_400)
        #expect(feed.timeline.headsetFrames == 2_400 && feed.evidence.framesKept == 2_400)
    }

    @Test func swiftConcurrencyAcquireAwaitsTheRelease() async {
        let broker = CaptureLeaseBroker()
        guard case .success(let old) = broker.tryAcquire(.dictation) else { Issue.record("no lease"); return }
        old.started(.headset)
        old.release()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { old.partReleased(.headset) }
        let result = await broker.acquire(.conversation)
        guard case .success(let new) = result else { Issue.record("refused: \(result)"); return }
        #expect(new.waitedMs >= 30 && old.state == .released)
        #expect(await old.settled() == .released)
    }
}
