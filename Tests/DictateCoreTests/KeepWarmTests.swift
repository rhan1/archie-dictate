import Foundation
import Testing
@testable import DictateCore

/// Fake time: `sleep` advances the clock instantly, so a whole 2 h schedule runs in microseconds.
private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 0
    private var sleeps = 0
    private var pingTimes: [TimeInterval] = []
    /// Runs inside the Nth sleep (1-based) before it returns.
    var onSleep: (@Sendable (Int) -> Void)?
    var now: TimeInterval { lock.withLock { t } }
    func set(_ value: TimeInterval) { lock.withLock { t = value } }
    func sleep(_ seconds: TimeInterval) async {
        let n = lock.withLock { () -> Int in sleeps += 1; t += seconds; return sleeps }
        onSleep?(n)
        await Task.yield()
    }
    func ping() async { lock.withLock { pingTimes.append(t) } }
    var pings: [TimeInterval] { lock.withLock { pingTimes } }

    func scheduler(enabled: Bool = true) -> GroqKeepWarm {
        GroqKeepWarm(enabled: enabled, now: { [self] in now }, sleep: { [self] in await sleep($0) }, ping: { [self] in await ping() })
    }
}

@Suite("GroqKeepWarm")
struct KeepWarmTests {
    @Test func constantsMatchTheRequirement() {
        #expect(GroqKeepWarm.interval == 240 && GroqKeepWarm.idleCap == 7200)
        #expect(GroqKeepWarm.isEnabled(environment: [:]))
        #expect(GroqKeepWarm.isEnabled(environment: ["DICTATE_KEEPWARM": "1"]))
        #expect(!GroqKeepWarm.isEnabled(environment: ["DICTATE_KEEPWARM": "0"]))
    }

    @Test func pingsEvery240sFromActivityAndStopsAtTwoHoursIdle() async {
        let time = FakeTime()
        let keepWarm = time.scheduler()
        keepWarm.activity()
        await keepWarm.waitUntilIdle()
        // 240, 480, ... 6960: the tick at exactly 7200 s idle does not ping.
        #expect(time.pings == (1...29).map { TimeInterval($0 * 240) })
        #expect(keepWarm.pings == 29)
        #expect(time.now == 7200)
    }

    @Test func nextActivityResumesAfterTheCap() async {
        let time = FakeTime()
        let keepWarm = time.scheduler()
        keepWarm.activity()
        await keepWarm.waitUntilIdle()
        #expect(keepWarm.pings == 29)
        time.set(9000)
        keepWarm.activity()
        await keepWarm.waitUntilIdle()
        #expect(keepWarm.pings == 58)
        #expect(time.pings[29] == 9240 && time.pings.last == 9000 + 6960)
    }

    @Test func noPingWhileBusyAndBusyKeepsTheIdleClockFresh() async {
        let time = FakeTime()
        let keepWarm = time.scheduler()
        keepWarm.setBusy(true)
        keepWarm.activity()
        time.onSleep = { n in if n == 4 { keepWarm.setBusy(false) } }
        await keepWarm.waitUntilIdle()
        // Ticks 1-3 (t = 240...720) were busy; tick 4 (t = 960) is the first ping.
        // Busy refreshed the activity time to 720, so pings run until 720 + 7200.
        #expect(time.pings.first == 960 && time.pings.allSatisfy { $0 >= 960 })
        #expect(time.pings.last == 7680 && keepWarm.pings == 29)
    }

    @Test func busyForeverNeverPings() async {
        let time = FakeTime()
        let keepWarm = time.scheduler()
        keepWarm.setBusy(true)
        keepWarm.activity()
        time.onSleep = { n in if n == 60 { keepWarm.cancel() } }   // 60 ticks = 4 h, longer than the cap
        await keepWarm.waitUntilIdle()
        #expect(keepWarm.pings == 0 && time.pings.isEmpty)
    }

    @Test func disabledFlagNeverPings() async {
        let time = FakeTime()
        let keepWarm = time.scheduler(enabled: false)
        keepWarm.activity()
        await keepWarm.waitUntilIdle()
        #expect(keepWarm.pings == 0 && time.pings.isEmpty && time.now == 0)
    }

    @Test func cancelStopsIt() async {
        let time = FakeTime()
        let keepWarm = time.scheduler()
        keepWarm.activity()
        time.onSleep = { n in if n == 3 { keepWarm.cancel() } }
        await keepWarm.waitUntilIdle()
        #expect(keepWarm.pings == 2)
        keepWarm.cancel()
        #expect(keepWarm.pings == 2)
    }
}
