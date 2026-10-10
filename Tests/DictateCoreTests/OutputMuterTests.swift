import Foundation
import Testing
import DictateCore

final class MuteClock: CaptureScheduler {
    final class Job: CaptureCancellation {
        let at: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(at: TimeInterval, action: @escaping () -> Void) { self.at = at; self.action = action }
        func cancel() { cancelled = true }
    }
    var now: TimeInterval = 0
    var jobs: [Job] = []
    var waits: [TimeInterval] = []
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CaptureCancellation {
        let job = Job(at: now + delay, action: action); jobs.append(job); return job
    }
    func advance(_ delta: TimeInterval) {
        let end = now + delta
        while let job = jobs.filter({ !$0.cancelled && $0.at <= end }).min(by: { $0.at < $1.at }) {
            job.cancelled = true; now = max(now, job.at); job.action()
        }
        now = max(now, end)
    }
    func wait(_ delta: TimeInterval) { waits.append(delta); now += delta }
}

final class FakeOutput: OutputMuteDevice {
    var defaultUID: String? = "headset"
    var mute: [String: Bool] = ["headset": false, "speakers": false]
    var unsupported: Set<String> = []
    var writes: [(String, Bool)] = []
    var reads: [String] = []
    var silentlyFail = false
    var failWritesRemaining = 0
    var disagree = false
    var onWrite: (() -> Void)?
    var profile = "a2dp"
    var capturedA2DPMute = false
    private var observers: [UUID: () -> Void] = [:]
    private final class Observation: CaptureCancellation {
        var cancellation: (() -> Void)?
        init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
        func cancel() { cancellation?(); cancellation = nil }
        deinit { cancel() }
    }
    func defaultOutputUID() -> String? { defaultUID }
    func isMuted(uid: String) -> Bool? {
        reads.append(uid)
        guard !unsupported.contains(uid), let value = mute[uid] else { return nil }
        return disagree ? !value : value
    }
    func setMuted(_ muted: Bool, uid: String) -> Bool {
        writes.append((uid, muted)); onWrite?()
        guard mute[uid] != nil, !unsupported.contains(uid) else { return false }
        if failWritesRemaining > 0 { failWritesRemaining -= 1; return true }
        if !silentlyFail {
            mute[uid] = muted
            if profile == "a2dp" { capturedA2DPMute = muted }
        }
        return true
    }
    func observeChanges(uid: String, _ action: @escaping () -> Void) -> CaptureCancellation? {
        let id = UUID(); observers[id] = action
        return Observation { [weak self] in self?.observers[id] = nil }
    }
    func notifyChange() { Array(observers.values).forEach { $0() } }
    func flip(to profile: String, notify: Bool = true) {
        self.profile = profile
        if profile == "a2dp" { mute["headset"] = capturedA2DPMute }
        if notify { notifyChange() }
    }
    func flip(after delay: TimeInterval, clock: MuteClock, to profile: String, notify: Bool = true) {
        _ = clock.schedule(after: delay) { [weak self] in self?.flip(to: profile, notify: notify) }
    }
}

private final class MuteHarness {
    let out = FakeOutput()
    let clock = MuteClock()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-mute-\(UUID().uuidString)")
    var events: [OutputMuter.Event] = []
    lazy var muter: OutputMuter = {
        let m = OutputMuter(device: out, stateFile: file, clock: clock, retryWait: { [clock] in clock.wait($0) })
        m.onEvent = { [weak self] in self?.events.append($0) }
        return m
    }()
    var exists: Bool { FileManager.default.fileExists(atPath: file.path) }
    deinit { try? FileManager.default.removeItem(at: file) }
}

@Suite("OutputMuter")
struct OutputMuterTests {
    @Test func mutesOnLiveAndRestoresOnEnd() {
        let h = MuteHarness(); let m = h.muter
        h.out.onWrite = { #expect(h.exists) } // State precedes EVERY flag write.
        #expect(m.mute() == .muted)
        #expect(h.out.mute["headset"] == true)
        #expect(m.restore() == .restored)
        #expect(h.out.mute["headset"] == false)
        #expect(h.exists)
        #expect(m.restore() == nil)
        h.clock.advance(4.99); #expect(h.exists)
        h.clock.advance(0.01); #expect(!h.exists)
        h.out.onWrite = nil
    }
    @Test func priorMutedStaysMuted() {
        let h = MuteHarness(); h.out.mute["headset"] = true
        #expect(h.muter.mute() == .muted)
        #expect(h.muter.restore() == .restored)
        h.clock.advance(5)
        #expect(h.out.mute["headset"] == true)
        #expect(!h.exists)
        #expect(!h.events.contains(.muteReasserted))
    }
    @Test func deviceSwapRestoresTheOriginalDevice() {
        let h = MuteHarness(); _ = h.muter.mute()
        h.out.defaultUID = "speakers"
        #expect(h.muter.restore() == .restored)
        h.out.mute["headset"] = true; h.out.notifyChange()
        #expect(h.out.mute["headset"] == false)
        #expect(h.out.writes.allSatisfy { $0.0 == "headset" })
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func unsupportedFallsBackWithoutWriting() {
        let h = MuteHarness(); h.out.unsupported = ["headset"]
        #expect(h.muter.mute() == .unsupported)
        #expect(h.out.writes.isEmpty); #expect(!h.exists)
    }
    @Test func restoreVerifiesReadBack() {
        let h = MuteHarness(); _ = h.muter.mute()
        h.out.disagree = true
        #expect(h.muter.restore() == .restoreFailed)
        #expect(h.exists)
        #expect(h.clock.waits == [0.05, 0.05, 0.05])
        #expect(h.out.writes.count == 5) // Initial mute + initial restore + 3 retries.
        h.out.disagree = false
        #expect(h.muter.restore()?.rawValue == "restored(verified)")
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func retriesRecoverTransientSilentFailure() {
        let h = MuteHarness(); _ = h.muter.mute()
        h.out.failWritesRemaining = 2
        #expect(h.muter.restore() == .restored)
        #expect(h.clock.waits == [0.05, 0.05])
        #expect(h.out.mute["headset"] == false)
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func profileFlipAfterRestoreIsReasserted() {
        let h = MuteHarness()
        #expect(h.out.profile == "a2dp")
        _ = h.muter.mute(); h.out.flip(to: "hfp")
        #expect(h.muter.restore() == .restored)
        #expect(h.out.mute["headset"] == false)
        h.out.flip(after: 0.2, clock: h.clock, to: "a2dp")
        h.clock.advance(0.2)
        #expect(h.out.mute["headset"] == false)
        #expect(h.events.map(\.rawValue) == ["mute_reasserted=1"])
        #expect(h.exists)
        h.clock.advance(4.8); #expect(!h.exists)
    }
    @Test func scheduledChecksCatchProfileFlipWithoutNotification() {
        let h = MuteHarness(); _ = h.muter.mute(); h.out.flip(to: "hfp"); _ = h.muter.restore()
        h.out.flip(after: 0.2, clock: h.clock, to: "a2dp", notify: false)
        h.clock.advance(0.2); #expect(h.out.mute["headset"] == true)
        h.clock.advance(0.3); #expect(h.out.mute["headset"] == false)
        #expect(h.events == [.muteReasserted])
        for delta in [0.5, 1.0, 1.0, 2.0] {
            h.out.mute["headset"] = true
            h.clock.advance(delta)
            #expect(h.out.mute["headset"] == false)
        }
        #expect(h.events.count == 5); #expect(!h.exists)
    }
    @Test func userMuteAfterWindowIsLeftAlone() {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.clock.advance(5); #expect(!h.exists)
        let writes = h.out.writes.count
        h.out.mute["headset"] = true; h.out.notifyChange(); h.clock.advance(10)
        #expect(h.out.mute["headset"] == true)
        #expect(h.out.writes.count == writes)
        #expect(h.events.isEmpty)
        // The next dictation must preserve this deliberate true prior.
        _ = h.muter.mute(); _ = h.muter.restore(); h.clock.advance(5)
        #expect(h.out.mute["headset"] == true)
    }
    @Test func secondDictationDuringSettleKeepsTruePrior() throws {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.clock.advance(0.2); h.out.mute["headset"] = true
        #expect(h.muter.mute() == .muted)
        #expect(try String(contentsOf: h.file, encoding: .utf8) == "headset\t0")
        let writes = h.out.writes.count
        h.out.notifyChange(); h.clock.advance(5)
        #expect(h.out.mute["headset"] == true)
        #expect(h.out.writes.count == writes) // Cancelled old window cannot unmute a live run.
        #expect(h.exists)
        #expect(h.muter.restore() == .restored)
        #expect(h.out.mute["headset"] == false)
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func launchRecoveryRestoresAndLogs() throws {
        let h = MuteHarness()
        try "headset\t0".write(to: h.file, atomically: true, encoding: .utf8)
        h.out.mute["headset"] = true
        #expect(h.muter.recoverIfNeeded()?.rawValue == "mute_recovered=1")
        #expect(h.out.mute["headset"] == false)
        #expect(h.exists); #expect(h.muter.recoverIfNeeded() == nil)
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func failedRestoreKeepsStateFile() {
        let h = MuteHarness(); _ = h.muter.mute(); h.out.silentlyFail = true
        #expect(h.muter.restore()?.rawValue == "restore_failed")
        #expect(h.out.mute["headset"] == true)
        h.clock.advance(10); #expect(h.exists)
    }
    @Test func goneDeviceKeepsStateForLaterRecovery() {
        let h = MuteHarness(); _ = h.muter.mute(); h.out.mute["headset"] = nil
        #expect(h.muter.restore() == .restoreFailed); #expect(h.exists)
        h.out.mute["headset"] = true
        let relaunched = OutputMuter(device: h.out, stateFile: h.file, clock: h.clock, retryWait: { _ in })
        #expect(relaunched.recoverIfNeeded() == .unmuteRecovered)
        #expect(h.out.mute["headset"] == false)
        #expect(h.exists); h.clock.advance(5); #expect(!h.exists)
    }
    @Test func failedSettleKeepsStateAndStopsAfterWindow() {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.out.mute["headset"] = true; h.out.silentlyFail = true
        h.clock.advance(5); #expect(h.exists)
        #expect(h.events.contains(.restoreFailed))
        let writes = h.out.writes.count
        h.out.notifyChange(); h.clock.advance(10)
        #expect(h.out.writes.count == writes)
    }
    @Test func disappearanceDuringSettleKeepsState() {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.out.mute["headset"] = nil
        h.clock.advance(5); #expect(h.exists)
        #expect(h.events.contains(.restoreFailed))
    }
    @Test func crashDuringSettleCanRecover() {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.out.mute["headset"] = true
        let recovered = OutputMuter(device: h.out, stateFile: h.file, clock: h.clock, retryWait: { _ in })
        #expect(recovered.recoverIfNeeded() == .unmuteRecovered)
        #expect(h.out.mute["headset"] == false)
        #expect(h.exists)
    }
    @Test func unwriteableStateNeverMutes() throws {
        let h = MuteHarness()
        try "regular file, not a directory".write(to: h.file, atomically: true, encoding: .utf8)
        let m = OutputMuter(device: h.out, stateFile: h.file.appendingPathComponent("state"), clock: h.clock)
        #expect(m.mute() == .unsupported)
        #expect(h.out.writes.isEmpty)
    }
    @Test func terminationRestoreRechecksExistingWindow() {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.out.mute["headset"] = true // Quit before CoreAudio delivers the change.
        #expect(h.muter.restore() == nil)
        #expect(h.out.mute["headset"] == false)
        #expect(h.events == [.muteReasserted])
        #expect(h.exists)
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func lateTimerNeverReassertsAfterWindow() {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.clock.now = 6 // The main queue was stalled beyond the entire window.
        h.out.mute["headset"] = true
        let writes = h.out.writes.count
        h.clock.advance(0); h.out.notifyChange()
        #expect(h.out.writes.count == writes)
        #expect(h.out.mute["headset"] == true)
        #expect(h.exists) // A final clean read was never obtained.
    }
    @Test func secondDictationAfterLateWindowPreservesUserMute() throws {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.clock.now = 6 // Expired timers have not run yet; the user mutes now.
        h.out.mute["headset"] = true
        _ = h.muter.mute()
        #expect(try String(contentsOf: h.file, encoding: .utf8) == "headset\t1")
        _ = h.muter.restore()
        #expect(h.out.mute["headset"] == true)
    }
    @Test func failedLaunchRecoveryCanRetryWhenDeviceReturns() throws {
        let h = MuteHarness()
        try "headset\t0".write(to: h.file, atomically: true, encoding: .utf8)
        h.out.mute["headset"] = nil
        #expect(h.muter.recoverIfNeeded() == .restoreFailed)
        #expect(h.exists)
        h.out.mute["headset"] = true
        #expect(h.muter.recoverIfNeeded() == .unmuteRecovered)
        #expect(h.out.mute["headset"] == false)
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func differentDeviceSecondRunRetainsBothCrashRecords() throws {
        let h = MuteHarness(); _ = h.muter.mute(); _ = h.muter.restore()
        h.clock.advance(1); h.out.defaultUID = "speakers"; _ = h.muter.mute()
        #expect(try String(contentsOf: h.file, encoding: .utf8) == "headset\t0\nspeakers\t0")
        h.out.mute["headset"] = true; h.out.notifyChange()
        #expect(h.out.mute["headset"] == false)
        #expect(h.out.mute["speakers"] == true)
        h.clock.advance(4)
        #expect(try String(contentsOf: h.file, encoding: .utf8) == "speakers\t0")
        _ = h.muter.restore(); h.clock.advance(5); #expect(!h.exists)
    }
}
