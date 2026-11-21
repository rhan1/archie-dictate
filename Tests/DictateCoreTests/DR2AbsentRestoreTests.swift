import Foundation
import Testing
import DictateCore

/// 1.29.16 (Archie 62.8.10, deep review H6 = F1-A5/A2-A7): the headset leaves while its output is muted.
/// Before: `restore()` kept the gone device in `active` → `mutedUIDs == [headset]` (Archie: every answer
/// "output unavailable") and the next `mute()` returned `.muted` without touching the speakers.
@Suite("DR2 absent device at restore (H6)")
struct DR2AbsentRestoreTests {
    final class Rig {
        let out = FakeOutput()
        let clock = MuteClock()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dr2-h6-\(UUID().uuidString)")
        var notes: [String] = []
        lazy var muter: OutputMuter = {
            let m = OutputMuter(device: out, stateFile: file, clock: clock, retryWait: { [clock] in clock.wait($0) })
            m.onNote = { [weak self] in self?.notes.append($0) }
            return m
        }()
        var text: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
        deinit { try? FileManager.default.removeItem(at: file) }
    }

    @Test func headsetGoneWhileMutedIsCarriedAndTheSpeakersMuteNext() {
        let rig = Rig()
        #expect(rig.muter.mute() == .muted)
        #expect(rig.out.mute["headset"] == true)
        rig.out.mute["headset"] = nil; rig.out.defaultUID = "speakers"        // powered off / out of range
        let event = rig.muter.restore()
        let held = rig.muter.mutedUIDs
        rig.out.writes = []
        let next = rig.muter.mute()
        let speakerWrites = rig.out.writes.filter { $0.0 == "speakers" && $0.1 }.count
        print("P H6 restore=\(event?.rawValue ?? "nil") muted_uids=\(held) next=\(next.rawValue) speaker_mute_writes=\(speakerWrites) record_kept=\(rig.text.contains("headset\t0") ? 1 : 0)")
        #expect(held.isEmpty)                                                   // RED: ["headset"]
        #expect(next == .muted)
        #expect(speakerWrites == 1)                                            // RED: 0 (nothing muted)
        #expect(rig.out.mute["speakers"] == true)
        #expect(rig.text.contains("headset\t0"))                               // carried for its return
        #expect(rig.notes.contains("mute_record_absent=1"))
        #expect(rig.muter.restore() == .restored)
        #expect(rig.out.mute["speakers"] == false)
        rig.clock.advance(5)
        #expect(rig.text == "headset\t0")
    }

    @Test func headsetReturningAfterwardIsUnmuted() {
        let rig = Rig()
        _ = rig.muter.mute()
        rig.out.mute["headset"] = nil; rig.out.defaultUID = "speakers"
        _ = rig.muter.restore()
        rig.out.mute["headset"] = true; rig.out.defaultUID = "headset"         // back, with our flag on it
        #expect(rig.muter.recoverIfNeeded() == .unmuteRecovered)
        #expect(rig.out.mute["headset"] == false)
        rig.clock.advance(5)
        #expect(!FileManager.default.fileExists(atPath: rig.file.path))
        print("P H6 headset_returns_unmuted=\(rig.out.mute["headset"] == false ? 1 : 0)")
    }

    @Test func presentDeviceThatFailsToRestoreStillHeld() {
        // Control: a device that is still connected but will not unmute stays owned (unchanged).
        let rig = Rig()
        _ = rig.muter.mute()
        rig.out.silentlyFail = true
        #expect(rig.muter.restore() == .restoreFailed)
        print("P H6 CONTROL present_failure_held=\(rig.muter.mutedUIDs == ["headset"] ? 1 : 0)")
        #expect(rig.muter.mutedUIDs == ["headset"])
    }

    /// Fix pass (Codex H6-1): the headset returns still muted by us and becomes the default DURING a speakers
    /// capture → adopted (kept muted for the capture) and unmuted at its end, not left muted as "the user's".
    @Test func headsetReturningMidCaptureIsAdoptedAndUnmuted() {
        let rig = Rig()
        _ = rig.muter.mute()
        rig.out.mute["headset"] = nil; rig.out.defaultUID = "speakers"
        _ = rig.muter.restore()
        #expect(rig.muter.mute() == .muted)                                     // speakers capture
        rig.out.mute["headset"] = true; rig.out.defaultUID = "headset"
        rig.out.notifyOutput(.defaultChanged)
        let held = rig.muter.mutedUIDs
        #expect(rig.muter.restore() == .restored)
        rig.clock.advance(5)
        print("P H6 mid_capture_return held=\(held) headset_after=\(rig.out.mute["headset"].map { $0 ? 1 : 0 } ?? -1) record_left=\(FileManager.default.fileExists(atPath: rig.file.path) ? 1 : 0)")
        #expect(held == ["speakers", "headset"])
        #expect(rig.out.mute["headset"] == false)                              // RED: true (left muted)
        #expect(rig.out.mute["speakers"] == false)
        #expect(!FileManager.default.fileExists(atPath: rig.file.path))
    }

    /// Fix pass (Codex H6-1): a capture on the returned headset starts inside the speakers' 5 s settle window
    /// (launch-style recovery is skipped then) → the carried record is adopted, never deleted as "already muted".
    @Test func headsetReturningInsideAnotherSettleWindowKeepsItsRecord() {
        let rig = Rig()
        _ = rig.muter.mute()
        rig.out.mute["headset"] = nil; rig.out.defaultUID = "speakers"
        _ = rig.muter.restore()
        _ = rig.muter.mute(); _ = rig.muter.restore()                           // speakers now settling
        rig.clock.advance(1)
        rig.out.mute["headset"] = true; rig.out.defaultUID = "headset"
        let next = rig.muter.mute()
        let kept = rig.text.contains("headset\t0")
        _ = rig.muter.restore(); rig.clock.advance(5)
        print("P H6 return_in_settle_window next=\(next.rawValue) record_kept=\(kept ? 1 : 0) headset_after=\(rig.out.mute["headset"].map { $0 ? 1 : 0 } ?? -1)")
        #expect(next == .muted)                                                 // RED: already_muted (record deleted)
        #expect(kept)
        #expect(rig.out.mute["headset"] == false)
        #expect(!FileManager.default.fileExists(atPath: rig.file.path))
    }

    /// L6 control: a carried record taken on another profile is not adopted (the returned flag is not ours).
    @Test func carriedRecordFromAnotherProfileIsNotAdopted() {
        let rig = Rig()
        rig.out.reportsProfile = true; rig.out.profile = "a2dp"
        _ = rig.muter.mute()
        rig.out.mute["headset"] = nil; rig.out.defaultUID = "speakers"
        _ = rig.muter.restore()
        _ = rig.muter.mute(); _ = rig.muter.restore(); rig.clock.advance(1)
        rig.out.profile = "hfp"; rig.out.mute["headset"] = true; rig.out.defaultUID = "headset"
        let next = rig.muter.mute()
        print("P H6 CONTROL other_profile next=\(next.rawValue) headset_flag=\(rig.out.mute["headset"] == true ? 1 : 0)")
        #expect(next == .alreadyMuted)
        #expect(rig.out.mute["headset"] == true)
    }
}
