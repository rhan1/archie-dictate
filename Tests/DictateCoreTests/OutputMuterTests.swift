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
    /// v1.12.1 (L6): report `profile` as the output's profile (off: unknown, as before).
    var reportsProfile = false
    func outputProfile(uid: String) -> String? { reportsProfile ? profile : nil }
    private var observers: [UUID: () -> Void] = [:]
    private var outputObservers: [UUID: (OutputChange) -> Void] = [:]
    private final class Observation: CaptureCancellation {
        var cancellation: (() -> Void)?
        init(_ cancellation: @escaping () -> Void) { self.cancellation = cancellation }
        func cancel() { cancellation?(); cancellation = nil }
        deinit { cancel() }
    }
    func defaultOutputUID() -> String? { defaultUID }
    /// M1: present = the fake knows the device (an `unsupported` device is present but unreadable).
    func isPresent(uid: String) -> Bool { mute[uid] != nil }
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
    func observeOutputChanges(uid: String, _ action: @escaping (OutputChange) -> Void) -> CaptureCancellation? {
        let id = UUID(); outputObservers[id] = action
        return Observation { [weak self] in self?.outputObservers[id] = nil }
    }
    var outputObserverCount: Int { outputObservers.count }
    func notifyChange() { Array(observers.values).forEach { $0() } }
    /// A CoreAudio change reaches both watches (settle windows and the live dictation).
    func notifyOutput(_ reason: OutputChange) {
        notifyChange()
        Array(outputObservers.values).forEach { $0(reason) }
    }
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
    var notes: [String] = []
    lazy var muter: OutputMuter = {
        let m = OutputMuter(device: out, stateFile: file, clock: clock, retryWait: { [clock] in clock.wait($0) })
        m.onEvent = { [weak self] in self?.events.append($0) }
        m.onNote = { [weak self] in self?.notes.append($0) }
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
        // v1.12.1 (L6): an output that already reads muted is not owned — nothing is written or restored.
        let h = MuteHarness(); h.out.mute["headset"] = true
        #expect(h.muter.mute().rawValue == "already_muted")
        #expect(h.muter.restore() == nil)
        #expect(h.out.writes.isEmpty)
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
        // v1.12.1 (L6): the user's mute is not owned, and the expired window's record is dropped (a
        // later launch recovery must not unmute it either).
        #expect(!h.exists)
        _ = h.muter.restore()
        #expect(h.out.mute["headset"] == true)
        #expect(h.out.writes.count == 2)                                    // the first run's mute and restore only
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

    // v1.9 (L2): the mute is held for the whole dictation, across the headset's profile flips.
    @Test func flagResetByProfileFlipIsReapplied() {
        let h = MuteHarness()
        #expect(h.muter.mute() == .muted)
        h.out.profile = "hfp"; h.out.mute["headset"] = false   // the flip reset the device's flag
        h.out.notifyOutput(.rateChanged)
        #expect(h.out.mute["headset"] == true)
        #expect(h.muter.reapplied == 1)
        #expect(h.notes == ["mute_reapplied=1 uid=headset reason=rate_changed"])
        h.out.profile = "a2dp"; h.out.mute["headset"] = false
        h.out.notifyOutput(.defaultChanged)
        #expect(h.out.mute["headset"] == true)
        #expect(h.muter.reapplied == 2)
        #expect(h.muter.restore() == .restored)
        #expect(h.out.mute["headset"] == false)
        #expect(h.muter.reapplied == 2)    // still readable for the timeline after restore
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func aMutedFlagIsNotRewritten() {
        let h = MuteHarness(); _ = h.muter.mute()
        let writes = h.out.writes.count
        h.out.notifyOutput(.devicesChanged)
        #expect(h.out.writes.count == writes)
        #expect(h.muter.reapplied == 0); #expect(h.notes.isEmpty)
    }
    @Test func secondUIDDuringDictationIsMutedAndRestored() throws {
        let h = MuteHarness(); _ = h.muter.mute()
        h.out.mute["headset-hfp"] = false
        h.out.onWrite = { #expect(h.exists) }
        h.out.defaultUID = "headset-hfp"   // the stack exposes HFP output as another device
        h.out.notifyOutput(.defaultChanged)
        h.out.onWrite = nil
        #expect(h.out.mute["headset-hfp"] == true)
        #expect(h.muter.mutedUIDs == ["headset", "headset-hfp"])
        #expect(try String(contentsOf: h.file, encoding: .utf8) == "headset\t0\nheadset-hfp\t0")
        #expect(h.notes == ["mute_reapplied=1 uid=headset-hfp reason=default_changed"])
        #expect(h.muter.restore() == .restored)
        #expect(h.out.mute["headset"] == false)
        #expect(h.out.mute["headset-hfp"] == false)
        h.clock.advance(5); #expect(!h.exists)
    }
    @Test func restoreRestoresEveryUIDInOrder() {
        let h = MuteHarness(); _ = h.muter.mute()
        h.out.mute["headset-hfp"] = true    // already muted by the user: v1.12.1 (L6) never owns it
        h.out.mute["speakers"] = false
        h.out.defaultUID = "headset-hfp"; h.out.notifyOutput(.defaultChanged)
        h.out.defaultUID = "speakers"; h.out.notifyOutput(.defaultChanged)
        #expect(h.muter.mutedUIDs == ["headset", "speakers"])
        let before = h.out.writes.count
        #expect(h.muter.restore() == .restored)
        let restoreWrites = h.out.writes[before...].map { "\($0.0)=\($0.1)" }
        #expect(restoreWrites == ["headset=false", "speakers=false"])          // restore may only unmute
        #expect(h.out.mute["headset-hfp"] == true)
        #expect(h.muter.mutedUIDs.isEmpty)
    }
    @Test func aFailedSecondRestoreKeepsItOwned() {
        let h = MuteHarness(); _ = h.muter.mute()
        h.out.mute["speakers"] = false
        h.out.defaultUID = "speakers"; h.out.notifyOutput(.defaultChanged)
        h.out.mute["speakers"] = nil         // gone before the end
        #expect(h.muter.restore() == .restoreFailed)
        #expect(h.out.mute["headset"] == false)
        #expect(h.muter.mutedUIDs == ["speakers"])
        #expect(h.exists)
    }
    @Test func hfpWithoutMuteIsNotedAndTheA2DPFlagKept() {
        let h = MuteHarness(); _ = h.muter.mute()
        h.out.mute["headset-hfp"] = false
        h.out.unsupported = ["headset-hfp"]
        h.out.defaultUID = "headset-hfp"
        h.out.notifyOutput(.defaultChanged); h.out.notifyOutput(.rateChanged)
        #expect(h.notes == ["mute_unsupported_uid=headset-hfp"])
        #expect(!h.out.writes.contains { $0.0 == "headset-hfp" })
        #expect(h.out.mute["headset"] == true)
        #expect(h.muter.mutedUIDs == ["headset"])
    }
    @Test func restoreStopsReasserting() {
        let h = MuteHarness(); _ = h.muter.mute()
        #expect(h.out.outputObserverCount == 1)
        #expect(h.muter.restore() == .restored)
        #expect(h.out.outputObserverCount == 0)
        h.clock.advance(5)
        h.out.mute["headset"] = false; h.out.notifyOutput(.rateChanged)
        #expect(h.muter.reapplied == 0)
        #expect(h.out.mute["headset"] == false)
    }

    // MARK: v1.12.1 (L6) — restore may only unmute (10-13 15:33, Archie 42.0, XM6, session 4b18ada4)

    private static let sony = "58-18-62-21-1C-6A:output"
    private func sonyHarness() -> MuteHarness {
        let h = MuteHarness()
        h.out.defaultUID = Self.sony
        h.out.mute = [Self.sony: false, "speakers": false]
        return h
    }

    /// The poisoned record on disk at 15:38 (`muted.state` = `58-18-62-21-1C-6A:output\t1`): a host
    /// launch must not write muted=1 to the headset; the record is dropped.
    @Test func launchRecoveryNeverWritesMutedFromAStalePriorOneRecord() throws {
        let h = sonyHarness()
        try "\(Self.sony)\t1".write(to: h.file, atomically: true, encoding: .utf8)
        let event = h.muter.recoverIfNeeded()
        #expect(!h.out.writes.contains { $0.1 == true })
        #expect(h.out.mute[Self.sony] == false)
        #expect(event == nil)
        #expect(!h.exists)
    }

    /// 15:33:06: the headset is already on HFP and its HFP-side flag reads 1 when `mute()` runs. v1.12
    /// owned prior=1, restore wrote muted=1 (29.121 `Set muteControl … to 1`) and the A2DP return to 0
    /// logged `restore_failed` ×4. Now nothing is owned or written and the settle window stays silent.
    @Test func alreadyMutedHFPFlagIsNeverOwnedNorRestoredToMuted() {
        let h = sonyHarness()
        h.out.profile = "hfp"; h.out.reportsProfile = true
        h.out.mute[Self.sony] = true                                        // stale HFP-side flag
        #expect(h.muter.mute().rawValue == "already_muted")
        #expect(h.muter.restore() == nil)
        #expect(!h.out.writes.contains { $0.1 == true })
        h.out.profile = "a2dp"; h.out.mute[Self.sony] = false; h.out.notifyChange()   // the A2DP return (29.428 → 0)
        h.clock.advance(5)
        #expect(!h.events.contains(.restoreFailed))
        #expect(!h.exists)
    }

    /// Every later dictation re-poisoned itself: `mute()` ran `recoverIfNeeded()` on the stale record
    /// first. Now the only true write is the mute itself, and the end leaves the output audible.
    @Test func dictationWithAStaleRecordMutesOnceAndRestoresAudible() throws {
        let h = sonyHarness()
        try "\(Self.sony)\t1".write(to: h.file, atomically: true, encoding: .utf8)
        #expect(h.muter.mute() == .muted)
        #expect(h.out.writes.filter { $0.1 == true }.count == 1)            // the mute, nothing else
        #expect(h.muter.restore() == .restored)
        #expect(h.out.mute[Self.sony] == false)
        h.clock.advance(5)
        #expect(!h.events.contains(.restoreFailed))
        #expect(!h.exists)
        #expect(h.out.writes.last.map { $0.1 } == false)
    }

    /// A new default output that already reads muted mid-dictation is left alone (never owned).
    @Test func reassertNeverOwnsAnAlreadyMutedNewOutput() throws {
        let h = sonyHarness()
        #expect(h.muter.mute() == .muted)
        h.out.mute["speakers"] = true
        h.out.defaultUID = "speakers"; h.out.notifyOutput(.defaultChanged)
        #expect(!h.out.writes.contains { $0.0 == "speakers" })
        #expect(h.muter.mutedUIDs == [Self.sony])
        #expect(try String(contentsOf: h.file, encoding: .utf8) == "\(Self.sony)\t0")
        #expect(h.muter.restore() == .restored)
        #expect(!h.out.writes.contains { $0.0 == "speakers" })
        #expect(h.out.mute["speakers"] == true)
    }

    /// The record names the profile it was taken on; across a profile change it describes another flag.
    @Test func recordCarriesItsProfileAndIsIgnoredAcrossAProfileChange() throws {
        let h = sonyHarness()
        h.out.profile = "hfp"; h.out.reportsProfile = true
        #expect(h.muter.mute() == .muted)
        #expect(try String(contentsOf: h.file, encoding: .utf8) == "\(Self.sony)\t0\thfp")
        // Crash. The next launch finds the headset on A2DP with its (other) flag muted by the user.
        h.out.profile = "a2dp"; h.out.mute[Self.sony] = true
        let writes = h.out.writes.count
        let relaunched = OutputMuter(device: h.out, stateFile: h.file, clock: h.clock, retryWait: { _ in })
        #expect(relaunched.recoverIfNeeded() == nil)
        #expect(h.out.writes.count == writes)
        #expect(h.out.mute[Self.sony] == true)
        #expect(!h.exists)
    }

    /// Regression: a flag that reads 0 at the start returns to 0 with no `restore_failed`, also across
    /// the HFP → A2DP return.
    @Test func unmutedStartRestoresToUnmutedWithoutRestoreFailed() throws {
        let h = sonyHarness()
        h.out.profile = "hfp"; h.out.reportsProfile = true
        #expect(h.muter.mute() == .muted)
        #expect(h.muter.restore() == .restored)
        #expect(h.out.mute[Self.sony] == false)
        h.out.flip(after: 0.3, clock: h.clock, to: "a2dp")
        h.clock.advance(5)
        #expect(h.out.mute[Self.sony] == false)
        #expect(!h.events.contains(.restoreFailed))
        #expect(!h.exists)
    }
}
