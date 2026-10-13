import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

/// v1.13 (L4): proving that WAVInjectedRecorder.stop() keeps a final word that ended
/// exactly 120 ms before the stop, on every relevant scenario and arm.
@Suite("StopTail")
struct StopTailTests {
    static let rate = 24_000
    static let wordFrames = 6_000      // 250 ms tone burst
    static let gapFrames = 2_400       // 100 ms gap of digital silence
    static let leadFrames = 6_720      // 280 ms lead (allows headset takeover at 150 ms)
    static let tailFrames = 2_880      // 120 ms pad of exact zeros after the final word
    static let totalWords = 6

    /// 0.28 s lead, 5 words with 100 ms gaps, 6th word with NO gap, then 120 ms tail zeros.
    /// Total duration: 0.28 + 5 * 0.35 + 0.25 + 0.12 = 2.40 s (exactly 24 ticks of 100 ms).
    static func clip() -> [Int16] {
        var out = (0..<leadFrames).map { Int16($0 % 2 == 0 ? 40 : -40) }
        for word in 0..<totalWords {
            let hz = 180.0 + Double(word) * 23.0
            out += (0..<wordFrames).map { Int16(8_000 * sin(Double($0) * 2 * .pi * hz / Double(rate))) }
            if word < totalWords - 1 {
                out += [Int16](repeating: 0, count: gapFrames)
            }
        }
        out += [Int16](repeating: 0, count: tailFrames)
        return out
    }

    static func wordStart(_ word: Int) -> Int { leadFrames + word * (wordFrames + gapFrames) }

    struct Run {
        var stats: AudioRecorder.CaptureStats
        var notes: [(ms: Int, line: String)]
        var pcm: [Int16]
        var captured: [Float]
    }

    static func run(_ clip: [Int16], scenario: WAVInjectedRecorder.Scenario, arm: WAVInjectedRecorder.Arm,
                    ticks: Int, configure: (WAVInjectedRecorder) -> Void) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-stoptail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("words.wav")
        try WAVEncoder.encode(samples: clip, sampleRate: rate, channels: 1).write(to: url)
        let recorder = WAVInjectedRecorder(url: url, scenario: scenario)
        recorder.manualPacing = true
        recorder.arm = arm
        recorder.note = { _ in }
        configure(recorder)
        let lock = NSLock()
        var pcm: [Int16] = []
        recorder.onPCMChunk = { chunk in lock.withLock { pcm += chunk } }
        try recorder.start()
        for _ in 0..<ticks { recorder.step() }
        let captured = recorder.stop()
        return Run(stats: recorder.stats, notes: recorder.timedNotes, pcm: lock.withLock { pcm }, captured: captured)
    }

    static func runCase(scenario: WAVInjectedRecorder.Scenario, arm: WAVInjectedRecorder.Arm) throws {
        let clip = Self.clip()
        let lastWord = totalWords - 1
        let lastWordClipStart = wordStart(lastWord)
        let speechFrames = lastWordClipStart + wordFrames
        let speechDuration = Double(speechFrames) / Double(rate)
        let pauseLength: TimeInterval = 0.5
        let pauseAt = Double(wordStart(3) + wordFrames) / Double(rate)

        let totalDuration = speechDuration + Double(tailFrames) / Double(rate) + (scenario == .pauseZeros ? pauseLength : 0)
        let rawTicks = totalDuration / 0.1
        let ticks = Int(rawTicks.rounded())
        #expect(abs(rawTicks - Double(ticks)) < 1e-6, "Ticks must be a whole integer: \(rawTicks)")

        let run = try Self.run(clip, scenario: scenario, arm: arm, ticks: ticks) { recorder in
            if scenario == .pauseZeros {
                recorder.pauseAt = pauseAt
                recorder.pauseLength = pauseLength
            }
        }

        let insertedFrames = scenario == .pauseZeros ? Int(pauseLength * Double(rate)) : 0
        let lastWordOutStart = lastWordClipStart + insertedFrames
        let expectedWord = Array(clip[lastWordClipStart..<(lastWordClipStart + wordFrames)])

        let pcmPresent = run.pcm.count >= lastWordOutStart + wordFrames &&
            Array(run.pcm[lastWordOutStart..<(lastWordOutStart + wordFrames)]) == expectedWord

        let capturedWordInt16: [Int16] = run.captured.count >= lastWordOutStart + wordFrames ?
            Array(run.captured[lastWordOutStart..<(lastWordOutStart + wordFrames)].map { Int16(round($0 * 32768)) }) : []
        let capturedPresent = capturedWordInt16 == expectedWord

        let isPresent = pcmPresent && capturedPresent
        let finalWordStr = isPresent ? "present" : "missing"

        print("L4 scenario=\(scenario.rawValue) arm=\(arm.rawValue) final_word=\(finalWordStr) stop_after_word_ms=120 recording_ms=\(run.stats.recordingMs) carrier=\(run.stats.carrier)")

        #expect(isPresent, "Final word was not present for scenario=\(scenario.rawValue) arm=\(arm.rawValue)")
        #expect(pcmPresent, "Delivered PCM missing final word samples")
        #expect(capturedPresent, "Captured Float array from stop() missing final word samples")
    }

    @Test
    func plainKeepsFinalWordEnded120msBeforeStop() throws {
        try Self.runCase(scenario: .plain, arm: .engine)
    }

    @Test(arguments: WAVInjectedRecorder.Arm.allCases)
    func pauseZerosKeepsFinalWordEnded120msBeforeStop(arm: WAVInjectedRecorder.Arm) throws {
        try Self.runCase(scenario: .pauseZeros, arm: arm)
    }

    /// Positive control (the gate's RED): the chord lands ON the last word — the stop at 2.2 s cuts its
    /// final 80 ms — and the detector reports it missing. A4's "Thanks" would read like this.
    @Test func chordOnTheLastWordIsDetectedAsMissing() throws {
        let clip = Self.clip()
        let run = try Self.run(clip, scenario: .plain, arm: .engine, ticks: 22) { _ in }
        let start = Self.wordStart(Self.totalWords - 1), n = Self.wordFrames
        let intact = run.pcm.count >= start + n && Array(run.pcm[start..<(start + n)]) == Array(clip[start..<(start + n)])
        print("L4 control chord_on_word final_word=\(intact ? "present" : "missing") stop_before_word_end_ms=80 recording_ms=\(run.stats.recordingMs)")
        #expect(!intact)
    }
}
