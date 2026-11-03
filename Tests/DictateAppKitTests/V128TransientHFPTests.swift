import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.28 B1: a dictation started ~100 ms after the previous one released found the headset still on HFP
/// (f243a0c8, 2026-11-03, `bt_start=hfp warm_ms=494`). The link was collapsing back to A2DP: the engine
/// stopped (+988), its re-attach brought zeros, the escalation's restart (+3402) re-requested HFP, and the
/// restarted engine's stop (+3654) was owed nothing for the remaining 30 s — `carrier=builtin:0-35323
/// headset_carried_ms=0`. `transient_hfp` replays that timeline on the media clock. No mic, no Bluetooth.
@Suite("V128TransientHFP", .serialized)
struct V128TransientHFPTests {
    private struct MissingEvent: Error { let event: String }

    struct Run {
        var stats: AudioRecorder.CaptureStats
        var notes: [(ms: Int, line: String)]
        var pcm: [Int16]
        func first(_ prefix: String) -> Int? { notes.first { $0.line.hasPrefix(prefix) }?.ms }
        var recoveryTimeline: String {
            notes.filter { note in ["bt_recovery", "headset_restart", "bridge_switch", "bridge_src"].contains { note.line.hasPrefix($0) } }
                .map { "\($0.ms):\($0.line.split(separator: " ").prefix(3).joined(separator: " "))" }.joined(separator: " | ")
        }
    }

    private static func tone(seconds: Double) -> [Int16] {
        (0..<Int(seconds * 24_000)).map { Int16(8_000 * sin(Double($0) * 2 * .pi * 220 / 24_000)) }
    }

    /// One stepped run (no wall-clock deadline) of `scenario` for `mediaSeconds` of media time.
    static func stepped(_ scenario: WAVInjectedRecorder.Scenario, mediaSeconds: Double,
                        configure: (WAVInjectedRecorder) -> Void = { _ in }) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-v128-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try WAVEncoder.encode(samples: tone(seconds: mediaSeconds + 1), sampleRate: 24_000, channels: 1).write(to: url)
        let recorder = WAVInjectedRecorder(url: url, pace: 0.05, scenario: scenario)
        let lock = NSLock()
        var pcm: [Int16] = []
        recorder.note = { _ in }
        recorder.onPCMChunk = { chunk in lock.withLock { pcm += chunk } }
        recorder.manualPacing = true
        configure(recorder)
        try recorder.start()
        for _ in 0..<Int(mediaSeconds * 10 + 0.5) { recorder.step() }
        _ = recorder.stop()
        return Run(stats: recorder.stats, notes: recorder.timedNotes, pcm: lock.withLock { pcm })
    }

    static func fields(_ r: Run) -> String {
        "carrier=\(r.stats.carrier) headset_carried_ms=\(r.stats.headsetCarriedMs) bridge_src=\(r.stats.bridgeSource)"
            + " headset_restart=\(r.stats.headsetRestart ?? "-") \(r.stats.ioHeld)"
    }

    /// RED on 3a48d95: the restarted engine's stop is owed nothing — `carrier=builtin:0-6500 headset_carried_ms=0`,
    /// `io_obligation=open:format_changed reattaches=1`. GREEN: it gets its own re-attach and the headset recovers.
    @Test func transientHFPRestartedEngineStopIsRecovered() throws {
        let r = try Self.stepped(.transientHFP, mediaSeconds: 6.5)
        let recovered = r.first("bridge_switch=headset reason=recovered")
        print("B1 LITERAL transient_hfp \(Self.fields(r)) recovered_ms=\(recovered.map(String.init) ?? "none") :: \(r.recoveryTimeline)")
        #expect(recovered.map { $0 <= 4_800 } == true)
        #expect(r.stats.headsetCarriedMs > 0)
        #expect(r.stats.ioHeld.contains(" reattaches=2"))
        #expect(r.stats.ioHeld.contains(" io_obligation=none "))
    }

    /// C MISSING-EVENT (gate self-test): `V128_MISSING_EVENT=reattach` withholds every re-attach after the restart,
    /// so the second re-attach never comes; the gate fails with its literal, never hangs (media-clock bound).
    @Test func transientHFPSecondReattachGate() throws {
        let withheld = ProcessInfo.processInfo.environment["V128_MISSING_EVENT"] == "reattach"
        let r = try Self.stepped(.transientHFP, mediaSeconds: 6.5) { $0.reattachesWithheldAfterRestart = withheld }
        let reattaches = r.notes.filter { $0.line.hasPrefix("bt_recovery=reattach path=obligation") }.map(\.ms)
        guard let second = reattaches.dropFirst().first else {
            Issue.record("missing event=reattach after media 6.5s reattaches=\(reattaches)")
            throw MissingEvent(event: "reattach")
        }
        print("C LITERAL transient_hfp second_reattach_ms=\(second)")
        #expect(second >= 3_650)
    }

    // MARK: controls — each literal is pasted from 3a48d95 and from 1.28

    @Test func controlWarmHFPTakeover() throws {
        let r = try WarmStartTests.run(arm: .engine, warm: true)
        print("B1 CONTROL warm_hfp takeover_ms=\(r.takeoverMs.map(String.init) ?? "none") carrier=\(r.carrier)")
        #expect(r.takeoverMs.map { $0 <= 300 } == true)
    }

    @Test func controlPlain() throws {
        let r = try Self.stepped(.plain, mediaSeconds: 4.0)
        let sum = r.pcm.reduce(0) { $0 &+ Int($1) }
        print("B1 CONTROL plain \(Self.fields(r)) pcm_samples=\(r.pcm.count) pcm_sum=\(sum)")
        #expect(r.pcm.count == 96_000)
    }

    @Test func controlHeadsetZeros() throws {
        let r = try Self.stepped(.headsetZeros, mediaSeconds: 4.0)
        print("B1 CONTROL headset_zeros \(Self.fields(r)) pcm_samples=\(r.pcm.count)")
        #expect(r.stats.headsetCarriedMs == 0)
    }

    @Test func controlBuiltinStartSlow() throws {
        let r = try Self.stepped(.builtinStartSlow, mediaSeconds: 4.0)
        let fail = r.notes.first { $0.line.hasPrefix("fail reason=") }?.line ?? "none"
        print("B1 CONTROL builtin_start_slow \(Self.fields(r)) fail=\(fail) pcm_samples=\(r.pcm.count)")
        #expect(fail == "none")
        #expect(r.stats.carrier.contains(",headset:"))
    }
}
