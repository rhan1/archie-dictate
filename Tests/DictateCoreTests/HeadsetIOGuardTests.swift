import Testing
@testable import DictateCore

/// v1.10 L1: one re-attach from the first configuration notification, then hands off for 1 s.
@Suite("HeadsetIOGuard")
struct HeadsetIOGuardTests {
    @Test func autoStoppedReattachesOnceThenHoldsForOneSecond() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(io.allows(at: 10) && !io.convertsInTap)       // before the first notification: start/rebuild/align allowed
        #expect(io.configurationChanged(at: 10.242, engineRunning: false) == .reattach)
        #expect(io.convertsInTap)
        #expect(!io.allows(at: 10.3) && !io.allows(at: 11.241))
        #expect(abs(io.remaining(at: 10.742) - 0.5) < 1e-9)
        #expect(io.configurationChanged(at: 10.45, engineRunning: false) == .handsOff(until: 10.242 + HeadsetIOGuard.handsOff))
        #expect(io.configurationChanged(at: 11.0, engineRunning: true) == .handsOff(until: 11.242))
        #expect(io.allows(at: 11.242) && io.remaining(at: 11.3) == 0)
        #expect(io.configurationChanged(at: 11.5, engineRunning: false) == .episode)   // after the window: the episode decides
        #expect(io.heldNote == "io_held=2 config_notifications=4")
    }

    @Test func aRunningEngineIsLeftAlone() {
        var io = HeadsetIOGuard(bluetooth: true)
        #expect(io.configurationChanged(at: 1, engineRunning: true) == .leaveRunning)
        #expect(!io.allows(at: 1.5))
    }

    @Test func otherInputsAreCountedButNeverHeld() {
        var io = HeadsetIOGuard(bluetooth: false)
        #expect(io.configurationChanged(at: 1, engineRunning: false) == .episode)
        #expect(io.allows(at: 1.01) && !io.convertsInTap && io.remaining(at: 1.01) == 0)
        io.record(.retap); io.record(.start)
        #expect(io.note == "io_ops=start:1 stop:0 rebuild:0 retap:1")
    }

    @Test func noteCountsEveryOperation() {
        var io = HeadsetIOGuard(bluetooth: true)
        for op in [HeadsetIOGuard.Op.start, .start, .stop, .rebuild, .retap, .retap, .retap] { io.record(op) }
        #expect(io.note == "io_ops=start:2 stop:1 rebuild:1 retap:3")
        io.record(.align)
        io.deferred()
        #expect(io.note == "io_ops=start:2 stop:1 rebuild:1 retap:3 align:1")
        #expect(io.heldNote == "io_held=1 config_notifications=0")
    }

    @Test func windowIsTheVerificationWindow() {
        #expect(HeadsetIOGuard.handsOff == BluetoothRecoveryEpisode.successWithin)
        #expect(HeadsetIOGuard.handsOff == 1.0)
    }
}
