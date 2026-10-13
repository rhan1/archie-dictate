import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.13 (L3): what a source switch does to the audio. A 1 kHz tone in syllable-shaped bursts runs
/// phase-continuous through the clip; a ±0.002 watermark makes every 2 ms window unique, so each output
/// sample's content position is recovered exactly and a splice reads as dropped (+ms) or repeated (−ms)
/// audio. (A bare 1 kHz tone cannot tell a whole 1 ms period apart.) WAV hatch `splice_lag`, media clock.
@Suite("Splice")
struct SpliceTests {
    static let rate = 24_000
    static let syllables: [(on: Int, off: Int)] = [(180, 90), (260, 130), (140, 70), (320, 110), (200, 150), (240, 80),
                                                  (160, 120), (300, 90), (220, 140), (190, 100), (280, 120), (210, 90)]
    static func clip() -> [Int16] {
        var out = [Int16](repeating: 0, count: rate * 4 / 10)                       // 0.4 s lead
        var seed: UInt64 = 0x5EED
        for (on, off) in syllables {
            let n = on * rate / 1000, ramp = rate / 100
            for k in 0..<n {
                let i = out.count
                let env = min(1, Double(min(k, n - k)) / Double(ramp))
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let mark = (Double(seed >> 33 & 0xFFFF) / 65535 - 0.5) * 0.004
                out.append(Int16((0.3 * env * sin(2 * .pi * 1000 * Double(i) / Double(rate)) + mark) * 32767))
            }
            out += [Int16](repeating: 0, count: off * rate / 1000)
        }
        return out
    }

    /// One discontinuity in the dictation's content: + = content skipped (lost), − = content heard twice;
    /// `silence` = output time inserted as digital zeros (a dead link's samples before a witnessed
    /// switchback replays from its onset) — nothing lost, nothing heard twice.
    struct Jump: CustomStringConvertible {
        var atMs: Int, ms: Double, silence: Bool
        var description: String { "\(silence ? "inserted_silence" : "jump")@\(atMs)ms=\(String(format: "%+.2f", ms))" }
    }

    /// Recovers every output sample's content position (exact 2 ms window match in either source's track)
    /// and lists every place where content and output stop advancing together.
    static func jumps(output: [Int16], headset: [Int16], builtin: [Int16], lagSamples: Int) -> (jumps: [Jump], known: Int) {
        let w = 48
        func index(_ track: [Int16]) -> [[Int16]: Int] {
            var map: [[Int16]: Int] = [:]
            for j in 0..<(track.count - w) where track[j..<(j + 8)].contains(where: { $0 != 0 }) {
                let key = Array(track[j..<(j + 8)])
                map[key] = map[key] == nil ? j : -1                                        // ambiguous: unused
            }
            return map
        }
        let hIndex = index(headset), bIndex = index(builtin)
        func content(_ i: Int) -> Int? {
            guard i + w <= output.count else { return nil }
            let window = Array(output[i..<(i + w)])
            let key = Array(window.prefix(8))
            if let j = hIndex[key], j >= 0, j + w <= headset.count, Array(headset[j..<(j + w)]) == window { return j - lagSamples }
            if let j = bIndex[key], j >= 0, j + w <= builtin.count, Array(builtin[j..<(j + w)]) == window { return j }
            return nil
        }
        var out: [Jump] = [], known = 0
        var previous: (i: Int, c: Int)?
        for i in 0..<(output.count - w) {
            guard let c = content(i) else { continue }
            known += 1
            if let p = previous {
                let jump = c - p.c - (i - p.i)
                if jump != 0 {
                    let silent = jump < 0 && output[(p.i + w)..<i].allSatisfy { $0 == 0 }
                    out.append(Jump(atMs: i * 1000 / rate, ms: Double(jump) * 1000 / Double(rate), silence: silent))
                }
            }
            previous = (i, c)
        }
        return (out, known)
    }

    struct Run { var carrier: String; var jumps: [Jump]; var known: Int; var notes: [String] }

    static func run(lag: TimeInterval, arm: WAVInjectedRecorder.Arm, dropAt: TimeInterval? = nil) throws -> Run {
        let clip = clip()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-splice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        try WAVEncoder.encode(samples: clip, sampleRate: 24_000, channels: 1).write(to: url)
        let recorder = WAVInjectedRecorder(url: url, scenario: .spliceLag)
        recorder.manualPacing = true
        recorder.arm = arm
        recorder.headsetLag = lag
        recorder.spliceDropAt = dropAt
        recorder.note = { _ in }
        let lock = NSLock()
        var pcm: [Int16] = []
        recorder.onPCMChunk = { chunk in lock.withLock { pcm += chunk } }
        try recorder.start()
        for _ in 0..<Int((Double(clip.count) / 24_000 * 10).rounded(.up)) { recorder.step() }
        _ = recorder.stop()
        let tracks = WAVInjectedRecorder.tracks(.spliceLag, wav: clip.map { Float($0) / 32768 }, pauseAt: 0, pauseLength: 0,
                                                dropAt: 0, headsetLag: lag, spliceDropAt: dropAt)
        func pcm16(_ x: [Float]) -> [Int16] { x.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) } }
        let carrier = recorder.stats.carrier
        let found = Self.jumps(output: lock.withLock { pcm }, headset: pcm16(tracks.headset),
                               builtin: pcm16(tracks.builtin), lagSamples: Int((lag * 24_000).rounded()))
        return Run(carrier: carrier, jumps: found.jumps, known: found.known,
                   notes: recorder.timedNotes.map(\.line).filter { $0.hasPrefix("splice_align") })
    }

    /// The headset's content trails its timestamps (60 / 150 ms) or leads them (−20 ms); a takeover,
    /// then (the link drops at 2.6 s) a witnessed switchback. Every switch: nothing lost or heard twice
    /// beyond 10 ms (time a dead link fed as zeros is reported as inserted silence, not a repeat).
    @Test(arguments: [(0.06, WAVInjectedRecorder.Arm.engine), (0.06, .auhal), (0.15, .engine), (0.037, .auhal),
                      (-0.02, .auhal), (0.0, .engine)])
    func everySwitchSplicesWithinTenMilliseconds(lag: Double, arm: WAVInjectedRecorder.Arm) throws {
        let run = try Self.run(lag: lag, arm: arm, dropAt: 2.6)
        let switches = run.carrier.split(separator: ",").count - 1
        let errors = run.jumps.filter { !$0.silence }
        let worst = errors.map { abs($0.ms) }.max() ?? 0
        let line = "L3 lag_ms=\(Int((lag * 1000).rounded())) arm=\(arm.rawValue) carrier=\(run.carrier) \(run.notes.joined(separator: " ")) switches=\(switches) worst_splice_ms=\(String(format: "%.2f", worst)) \(run.jumps) known_samples=\(run.known)"
        print(line)
        #expect(switches == 2, "\(line)")                                          // the takeover and the switchback
        #expect(worst <= 10, "\(line)")
        #expect(run.known > 48_000, "\(line)")
    }
}
