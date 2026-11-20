import Foundation
import Testing
import DictateCore

/// 1.29.13 (Archie 62.8.4, Raza 11-20 "when I went into dictation, the background volume is still playing"):
/// the host's conversation capture and the hosted dictation mute the SAME output flag. With two OutputMuter
/// instances each one's 5 s settle check reads the other's fresh mute as a profile-flip artefact and unmutes it
/// (62.8.3 log: conversation restore 22:48:14.536, dictation mute 16.331, `media=mute_reasserted=1 (settle)` at
/// 16.546 = restore + 2 s timer). One shared instance owns the flag across both.
@Suite("V12913 shared output muter")
struct V12913SharedMuterTests {
    final class Rig {
        let out = FakeOutput()
        let clock = MuteClock()
        var files: [URL] = []
        func muter() -> OutputMuter {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("v12913-\(UUID().uuidString)")
            files.append(file)
            return OutputMuter(device: out, stateFile: file, clock: clock, retryWait: { [clock] in clock.wait($0) })
        }
        deinit { files.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    /// Conversation capture mutes, ends (restore → settle window), dictation mutes 1.8 s later; read the flag
    /// across the conversation's settle timers, then end the dictation and let every window finish.
    static func dictationAfterConversation(shared: Bool, prior: Bool = false) -> (during: [Bool?], after: Bool?, rig: Rig) {
        let rig = Rig()
        rig.out.mute["headset"] = prior
        let conversation = rig.muter()
        let dictation = shared ? conversation : rig.muter()
        _ = conversation.mute(); rig.clock.advance(3)
        _ = conversation.restore()
        rig.clock.advance(1.8)
        _ = dictation.mute()
        var during: [Bool?] = []
        for _ in 0..<8 { rig.clock.advance(1); during.append(rig.out.mute["headset"]) }   // 2.8 … 9.8 s after
        _ = dictation.restore()
        rig.clock.advance(10)
        return (during, rig.out.mute["headset"], rig)
    }

    @Test func dictationAfterConversationStaysMuted() {
        let base = Self.dictationAfterConversation(shared: false)
        let red = base.during.allSatisfy { $0 == true } ? 1 : 0
        print("P RED dictation_after_conversation_stays_muted=\(red) (two muters, 62.8.3 wiring) during=\(base.during.map { $0.map { $0 ? 1 : 0 } ?? -1 })")
        #expect(red == 0)   // the base wiring IS the defect (proves this test can fail)
        let fix = Self.dictationAfterConversation(shared: true)
        let green = fix.during.allSatisfy { $0 == true } ? 1 : 0
        print("P GREEN dictation_after_conversation_stays_muted=\(green) (one shared muter) during=\(fix.during.map { $0.map { $0 ? 1 : 0 } ?? -1 })")
        #expect(green == 1)
        #expect(fix.after == false)
    }

    /// The reverse order: a conversation capture right after a dictation (inside its settle window).
    @Test func conversationAfterDictationStaysMuted() {
        func run(shared: Bool) -> [Bool?] {
            let rig = Rig()
            let dictation = rig.muter()
            let conversation = shared ? dictation : rig.muter()
            _ = dictation.mute(); rig.clock.advance(4); _ = dictation.restore()
            rig.clock.advance(0.7)
            _ = conversation.mute()
            var during: [Bool?] = []
            for _ in 0..<6 { rig.clock.advance(1); during.append(rig.out.mute["headset"]) }
            _ = conversation.restore(); rig.clock.advance(10)
            #expect(rig.out.mute["headset"] == false)
            return during
        }
        let red = run(shared: false).allSatisfy { $0 == true } ? 1 : 0
        let green = run(shared: true).allSatisfy { $0 == true } ? 1 : 0
        print("P RED conversation_after_dictation_stays_muted=\(red) (two muters)")
        print("P GREEN conversation_after_dictation_stays_muted=\(green) (one shared muter)")
        #expect(red == 0)
        #expect(green == 1)
    }

    /// restore_exact: the flag returns to exactly what it was before the conversation — unmuted stays unmuted,
    /// a user's own mute is never written or lifted — and no crash record is left behind.
    @Test func restoreExact() {
        let unmuted = Self.dictationAfterConversation(shared: true, prior: false)
        let userMuted = Self.dictationAfterConversation(shared: true, prior: true)
        let userWrites = userMuted.rig.out.writes.count
        let records = unmuted.rig.files.filter { FileManager.default.fileExists(atPath: $0.path) }.count
            + userMuted.rig.files.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        let exact = unmuted.after == false && userMuted.after == true && userWrites == 0 && records == 0
        print("P GREEN restore_exact=\(exact ? 1 : 0) prior0_after=\(unmuted.after == true ? 1 : 0) prior1_after=\(userMuted.after == true ? 1 : 0) user_flag_writes=\(userWrites) records_left=\(records)")
        #expect(exact)
    }

    /// The spec's HFP-start hypothesis: the headset is already in HFP when the dictation mutes, then returns to
    /// A2DP mid-dictation with its own (unmuted) flag; Mac speakers and an A2DP start for comparison.
    @Test func hfpStartAndOtherRoutes() {
        func run(start: String, uid: String, flipMid: Bool) -> (during: Bool?, after: Bool?) {
            let rig = Rig(); rig.out.defaultUID = uid; rig.out.profile = start
            let m = rig.muter()
            _ = m.mute(); rig.clock.advance(1)
            if flipMid {   // HFP → A2DP: the A2DP flag is a different, unmuted flag (v1.12.1 L6)
                rig.out.profile = start == "hfp" ? "a2dp" : "hfp"; rig.out.mute[uid] = false
                rig.out.notifyOutput(.rateChanged)
            }
            rig.clock.advance(3)
            let during = rig.out.mute[uid]
            _ = m.restore(); rig.clock.advance(10)
            return (during, rig.out.mute[uid])
        }
        let hfp = run(start: "hfp", uid: "headset", flipMid: true)
        print("P GREEN hfp_start_dictation_mutes_active_output=\(hfp.during == true && hfp.after == false ? 1 : 0) (route change mid-dictation re-muted; restored after)")
        #expect(hfp.during == true && hfp.after == false)
        let a2dp = run(start: "a2dp", uid: "headset", flipMid: false)
        let a2dpFlip = run(start: "a2dp", uid: "headset", flipMid: true)
        let speakers = run(start: "a2dp", uid: "speakers", flipMid: false)
        let same = [a2dp, a2dpFlip, speakers].allSatisfy { $0.during == true && $0.after == false }
        print("P GREEN a2dp_and_speaker_unchanged=\(same ? 1 : 0) (a2dp, a2dp→hfp mid-dictation, Mac speakers)")
        #expect(same)
    }
}
