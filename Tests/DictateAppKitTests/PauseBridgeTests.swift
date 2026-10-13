import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.13 (L1): a pause is not a dead headset. The WAV hatch's two-stream scenarios on both headset
/// arms (engine = 100 ms deliveries, auhal = 20 ms), stepped on the media clock — no mic, no
/// Bluetooth, no wall clock. "Words" are 250 ms tone bursts separated by 100 ms of exact zeros (the
/// Sony's gate between words); a word is INTACT when every one of its samples reaches the dictation
/// unchanged at its own position.
@Suite("PauseBridge")
struct PauseBridgeTests {
    static let rate = 24_000
    static let wordFrames = 6_000, gapFrames = 2_400, leadFrames = 7_200
    /// 0.3 s of a low non-zero floor (the headset takes over before the first word), then `count` words.
    static func clip(words count: Int) -> [Int16] {
        var out = (0..<leadFrames).map { Int16($0 % 2 == 0 ? 40 : -40) }
        for word in 0..<count {
            let hz = 180.0 + Double(word) * 23
            out += (0..<wordFrames).map { Int16(8_000 * sin(Double($0) * 2 * .pi * hz / Double(rate))) }
            out += [Int16](repeating: 0, count: gapFrames)
        }
        return out
    }
    static func wordStart(_ word: Int) -> Int { leadFrames + word * (wordFrames + gapFrames) }

    struct Run {
        var stats: AudioRecorder.CaptureStats
        var notes: [(ms: Int, line: String)]
        var pcm: [Int16]
        var midRunBuiltin: Int { stats.carrier.split(separator: ",").dropFirst().filter { $0.hasPrefix("builtin:") }.count }
    }

    static func run(_ clip: [Int16], scenario: WAVInjectedRecorder.Scenario, arm: WAVInjectedRecorder.Arm,
                    seconds: Double, configure: (WAVInjectedRecorder) -> Void) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("words.wav")
        try WAVEncoder.encode(samples: clip, sampleRate: 24_000, channels: 1).write(to: url)
        let recorder = WAVInjectedRecorder(url: url, scenario: scenario)
        recorder.manualPacing = true
        recorder.arm = arm
        recorder.note = { _ in }
        configure(recorder)
        let lock = NSLock()
        var pcm: [Int16] = []
        recorder.onPCMChunk = { chunk in lock.withLock { pcm += chunk } }
        try recorder.start()
        for _ in 0..<Int((seconds * 10).rounded(.up)) { recorder.step() }
        _ = recorder.stop()
        return Run(stats: recorder.stats, notes: recorder.timedNotes, pcm: lock.withLock { pcm })
    }

    // MARK: (a) speech, 2.0 s of exact zeros, speech; the built-in hears only its room floor.

    @Test(arguments: WAVInjectedRecorder.Arm.allCases)
    func aPauseOfDigitalSilenceKeepsTheHeadsetAndEveryWordAfterIt(arm: WAVInjectedRecorder.Arm) throws {
        let words = 12, before = 6
        let clip = Self.clip(words: words)
        let pauseAt = Double(Self.wordStart(before)) / Double(Self.rate)        // between word 6 and word 7
        let pause = 2.0
        let run = try Self.run(clip, scenario: .pauseZeros, arm: arm, seconds: Double(clip.count) / 24_000 + pause + 0.2) {
            $0.pauseAt = pauseAt; $0.pauseLength = pause
        }
        let inserted = Int(pause * Double(Self.rate))
        let intact = (before..<words).filter { word in
            let at = Self.wordStart(word), out = at + inserted
            return out + Self.wordFrames <= run.pcm.count && Array(run.pcm[out..<(out + Self.wordFrames)]) == Array(clip[at..<(at + Self.wordFrames)])
        }.count
        let line = "arm=\(arm.rawValue) carrier=\(run.stats.carrier) post_pause_words=\(intact)/\(words - before) switchbacks=\(run.stats.bridgeSwitchback)"
        print("L1a \(line)")
        #expect(run.midRunBuiltin == 0, "\(line)")
        #expect(intact == words - before, "\(line)")
        #expect(!run.notes.contains { $0.line.contains("bridge_switchback") || $0.line.hasPrefix("bridge_switch=builtin") }, "\(line)")
        #expect(!run.notes.contains { $0.line.hasPrefix("health=warn") || $0.line.hasPrefix("fail ") }, "\(line)")
    }

    // MARK: (b) the real failure: the headset goes to exact zeros while the built-in hears speech.

    @Test(arguments: WAVInjectedRecorder.Arm.allCases)
    func aDeadLinkWithTheBuiltinWitnessingSpeechFallsBackWithin150msLosingNothing(arm: WAVInjectedRecorder.Arm) throws {
        let clip = Self.clip(words: 8)
        let dropIndex = Self.wordStart(4) + 2_400                               // 100 ms into word 5
        let dropAt = Double(dropIndex) / Double(Self.rate)
        let run = try Self.run(clip, scenario: .headsetDrops, arm: arm, seconds: Double(clip.count) / 24_000 + 0.2) {
            $0.dropAt = dropAt
        }
        let switchMs = run.notes.first { $0.line.hasPrefix("bridge_switch=builtin") }.map { $0.ms }
        let after = switchMs.map { $0 - Int((dropAt * 1000).rounded()) }
        // Nothing lost: the built-in's own samples from the drop onward are in the dictation.
        let builtin = WAVInjectedRecorder.tracks(.headsetDrops, wav: clip.map { Float($0) / 32768 }, pauseAt: 0,
                                                 pauseLength: 0, dropAt: dropAt).builtin
        let probe = builtin[dropIndex..<(dropIndex + 240)].map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) }
        let found = (dropIndex..<(run.pcm.count - probe.count)).contains { Array(run.pcm[$0..<($0 + probe.count)]) == probe }
        let switchLine = run.notes.first { $0.line.hasPrefix("bridge_switch=builtin") }?.line ?? "none"
        let line = "arm=\(arm.rawValue) carrier=\(run.stats.carrier) switch_after_drop_ms=\(after.map(String.init) ?? "none") builtin_from_drop_kept=\(found) \(switchLine)"
        print("L1b \(line)")
        #expect(after.map { $0 >= 0 && $0 <= 150 } == true, "\(line)")
        #expect(found, "\(line)")
        #expect(switchLine.contains("reason=witness") && switchLine.contains("headset_peak=0.00000"), "\(line)")
        #expect(run.stats.carrier.hasSuffix("-\(run.stats.recordingMs)") && run.stats.carrier.contains(",builtin:"), "\(line)")
    }
}
