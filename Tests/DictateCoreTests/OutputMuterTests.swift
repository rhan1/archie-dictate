import Foundation
import Testing
import DictateCore

final class FakeOutput: OutputMuteDevice {
    var defaultUID: String? = "headset"
    var mute: [String: Bool] = ["headset": false, "speakers": false]
    var unsupported: Set<String> = []
    var writes: [(String, Bool)] = []
    func defaultOutputUID() -> String? { defaultUID }
    func isMuted(uid: String) -> Bool? { unsupported.contains(uid) ? nil : mute[uid] }
    func setMuted(_ muted: Bool, uid: String) -> Bool {
        guard mute[uid] != nil, !unsupported.contains(uid) else { return false }
        mute[uid] = muted
        writes.append((uid, muted))
        return true
    }
}

private func tempState() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dictate-mute-\(UUID().uuidString)")
}

@Suite("OutputMuter")
struct OutputMuterTests {
    @Test func mutesOnLiveAndRestoresOnEnd() {
        let out = FakeOutput(); let file = tempState()
        let m = OutputMuter(device: out, stateFile: file)
        #expect(m.mute() == .muted)
        #expect(out.mute["headset"] == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(m.restore() == .restored)
        #expect(out.mute["headset"] == false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(m.restore() == nil)                 // idempotent: second end path does nothing
    }

    @Test func priorMutedStaysMuted() {
        let out = FakeOutput(); out.mute["headset"] = true
        let m = OutputMuter(device: out, stateFile: tempState())
        #expect(m.mute() == .muted)
        #expect(m.restore() == .restored)
        #expect(out.mute["headset"] == true)
    }

    @Test func deviceSwapRestoresTheOriginalDevice() {
        let out = FakeOutput()
        let m = OutputMuter(device: out, stateFile: tempState())
        _ = m.mute()
        out.defaultUID = "speakers"                 // headset disconnected / switched mid-dictation
        #expect(m.restore() == .restored)
        #expect(out.mute["headset"] == false)
        #expect(out.writes.allSatisfy { $0.0 == "headset" })   // speakers never touched
    }

    @Test func unsupportedFallsBackWithoutWriting() {
        let out = FakeOutput(); out.unsupported = ["headset"]
        let file = tempState()
        let m = OutputMuter(device: out, stateFile: file)
        #expect(m.mute() == .unsupported)
        #expect(out.writes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func crashRecoveryRestoresPriorFromStateFile() {
        let out = FakeOutput(); let file = tempState()
        _ = OutputMuter(device: out, stateFile: file).mute()   // "crash": never restored
        #expect(out.mute["headset"] == true)
        let relaunched = OutputMuter(device: out, stateFile: file)
        #expect(relaunched.recoverIfNeeded() == .unmuteRecovered)
        #expect(out.mute["headset"] == false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(relaunched.recoverIfNeeded() == nil)
    }

    @Test func goneDeviceKeepsStateForLaterRecovery() {
        let out = FakeOutput(); let file = tempState()
        let m = OutputMuter(device: out, stateFile: file)
        _ = m.mute()
        out.mute["headset"] = nil                   // device disappeared
        #expect(m.restore() == .restorePending)
        #expect(FileManager.default.fileExists(atPath: file.path))
        out.mute["headset"] = true                  // reconnected, still muted
        #expect(OutputMuter(device: out, stateFile: file).recoverIfNeeded() == .unmuteRecovered)
        #expect(out.mute["headset"] == false)
    }
}
