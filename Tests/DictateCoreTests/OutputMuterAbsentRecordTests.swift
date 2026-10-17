import Foundation
import Testing
import DictateCore

/// M1 (2026-10-17 00:19): a crash record for a device that is no longer connected (Raza's Sony
/// headset, `58-18-62-21-1C-6A:output\t0\thfp`) made `mute()` return `.restoreFailed` before it
/// muted the CURRENT output, so media kept playing into the built-in mic on every dictation.
@Suite("OutputMuter absent-device records (M1)")
struct OutputMuterAbsentRecordTests {
    private final class Harness {
        let out = FakeOutput()
        let clock = MuteClock()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-m1-\(UUID().uuidString)")
        var notes: [String] = []
        lazy var muter: OutputMuter = {
            let m = OutputMuter(device: out, stateFile: file, clock: clock, retryWait: { [clock] in clock.wait($0) })
            m.onNote = { [weak self] in self?.notes.append($0) }
            return m
        }()
        var text: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
        init() {
            // The headset is gone (no entry: the device lookup fails); the speakers are the default.
            out.mute = ["speakers": false]
            out.defaultUID = "speakers"
        }
        deinit { try? FileManager.default.removeItem(at: file) }
    }
    static let absent = "58-18-62-21-1C-6A:output"

    @Test func absentRecordDoesNotBlockMutingTheCurrentOutput() throws {
        let h = Harness()
        try "\(Self.absent)\t0\thfp".write(to: h.file, atomically: true, encoding: .utf8)
        #expect(h.muter.mute() == .muted)
        #expect(h.out.mute["speakers"] == true)
        #expect(h.text.contains(Self.absent))                 // kept so it is restored when the headset returns
        #expect(h.text.contains("speakers\t0"))
        #expect(h.notes.contains("mute_record_absent=1"))
        #expect(h.muter.restore() == .restored)
        #expect(h.out.mute["speakers"] == false)
        h.clock.advance(5)
        #expect(h.text == "\(Self.absent)\t0\thfp")           // only the absent record remains
    }

    @Test func absentDeviceReturningIsUnmutedAndItsRecordDropped() throws {
        let h = Harness()
        try "\(Self.absent)\t0\thfp".write(to: h.file, atomically: true, encoding: .utf8)
        _ = h.muter.mute(); _ = h.muter.restore(); h.clock.advance(5)
        // The headset reconnects with the flag this app left on it.
        h.out.mute[Self.absent] = true
        #expect(h.muter.recoverIfNeeded() == .unmuteRecovered)
        #expect(h.out.mute[Self.absent] == false)
        #expect(!h.out.writes.contains { $0.0 == Self.absent && $0.1 == true })   // L6: restore only unmutes
        h.clock.advance(5)
        #expect(!FileManager.default.fileExists(atPath: h.file.path))
    }

    @Test func secondDictationInTheSameProcessStillMutes() throws {
        let h = Harness()
        try "\(Self.absent)\t0\thfp".write(to: h.file, atomically: true, encoding: .utf8)
        #expect(h.muter.mute() == .muted); _ = h.muter.restore(); h.clock.advance(5)
        #expect(h.out.mute["speakers"] == false)
        #expect(h.muter.mute() == .muted)
        #expect(h.out.mute["speakers"] == true)
        _ = h.muter.restore(); h.clock.advance(5)
        #expect(h.out.mute["speakers"] == false)
        #expect(h.text == "\(Self.absent)\t0\thfp")
    }

    @Test func recordMovedAwayWhileRunningIsStillCarriedNotLost() throws {
        // The 00:43 finding: the in-memory copy wrote the record back after the file was moved.
        let h = Harness()
        try "\(Self.absent)\t0\thfp".write(to: h.file, atomically: true, encoding: .utf8)
        _ = h.muter.mute(); _ = h.muter.restore(); h.clock.advance(5)
        try FileManager.default.removeItem(at: h.file)
        #expect(h.muter.mute() == .muted)
        #expect(h.out.mute["speakers"] == true)
        _ = h.muter.restore(); h.clock.advance(5)
        #expect(h.out.mute["speakers"] == false)
    }
}
