import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.13 (L2): the engine arm on a headset already on HFP (E4/W2 10-13 15:24: `carrier=builtin:0-2431`
/// on both, identical to the ms). WAV hatch `warm_hfp` on the media clock — no mic, no Bluetooth.
@Suite("WarmStart")
struct WarmStartTests {
    struct Result { var takeoverMs: Int?; var carrier: String; var notes: [(ms: Int, line: String)]; var ioOps: String }

    static func run(arm: WAVInjectedRecorder.Arm, warm: Bool, seconds: Double = 4.0) throws -> Result {
        let clip = PauseBridgeTests.clip(words: 10)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("words.wav")
        try WAVEncoder.encode(samples: clip, sampleRate: 24_000, channels: 1).write(to: url)
        let recorder = WAVInjectedRecorder(url: url, scenario: .warmHFP)
        recorder.manualPacing = true
        recorder.arm = arm
        recorder.warmRoute = warm
        recorder.note = { _ in }
        try recorder.start()
        for _ in 0..<Int((seconds * 10).rounded()) { recorder.step() }
        _ = recorder.stop()
        let carrier = recorder.stats.carrier
        let takeover = carrier.split(separator: ",").first { $0.hasPrefix("headset:") }
            .flatMap { Int($0.dropFirst("headset:".count).split(separator: "-").first ?? "") }
        return Result(takeoverMs: takeover, carrier: carrier, notes: recorder.timedNotes, ioOps: recorder.stats.ioOps)
    }

    static func describe(_ r: Result, _ label: String) -> String {
        let recovery = r.notes.filter { $0.line.hasPrefix("bt_recovery") || $0.line.hasPrefix("headset_restart") || $0.line.hasPrefix("bridge_switch") }
            .map { "\($0.ms):\($0.line.split(separator: " ").prefix(3).joined(separator: " "))" }.joined(separator: " | ")
        return "L2 \(label) takeover_ms=\(r.takeoverMs.map(String.init) ?? "none") carrier=\(r.carrier) :: \(recovery)"
    }

    @Test func warmHFPEngineArmCarriesWithin300ms() throws {
        let r = try Self.run(arm: .engine, warm: true)
        let line = Self.describe(r, "warm engine")
        print(line)
        #expect(r.takeoverMs.map { $0 <= 300 } == true, "\(line)")
        #expect(r.carrier.split(separator: ",").last?.hasPrefix("headset:") == true, "\(line)")
        #expect(!r.notes.contains { $0.line.hasPrefix("headset_restart=1") }, "\(line)")   // no restart chain
    }

    /// The same IO with the recorder having found A2DP at its start: the cold path is untouched.
    @Test func coldFlagKeepsTheV112RecoveryChain() throws {
        let r = try Self.run(arm: .engine, warm: false)
        let line = Self.describe(r, "cold-flag engine")
        print(line)
        #expect(r.takeoverMs.map { $0 >= 2_000 } == true, "\(line)")
        #expect(r.notes.contains { $0.line.hasPrefix("bt_recovery=hands_off path=configuration engine_running=1") }, "\(line)")
    }
}
