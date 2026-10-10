import Foundation
import Testing
import DictateCore
@testable import DictateAppKit

@Suite("WAVInjectedRecorderTests")
@MainActor
struct WAVInjectedRecorderTests {
    private func makeSineSamples(duration: Double = 0.35, sampleRate: Double = 24_000, frequency: Double = 440.0) -> [Int16] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            let val = sin(2.0 * Double.pi * frequency * t)
            return Int16((val * 32000.0).rounded())
        }
    }

    private func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    @Test func firstBufferAndChunksPaced() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samples = makeSineSamples()
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1)
        let wavURL = tempDir.appendingPathComponent("sine24k.wav")
        try wavData.write(to: wavURL)

        let recorder = WAVInjectedRecorder(url: wavURL, pace: 1.0)
        let lock = NSLock()
        var firstBufferCount = 0
        var deliveredChunks: [[Int16]] = []

        recorder.onFirstBuffer = {
            lock.withLock { firstBufferCount += 1 }
        }
        recorder.onPCMChunk = { chunk in
            lock.withLock { deliveredChunks.append(chunk) }
        }

        try recorder.start()

        let start = DispatchTime.now()
        while DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 1_000_000_000 {
            let done = lock.withLock { firstBufferCount >= 1 && !deliveredChunks.isEmpty }
            if done { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = recorder.stop()

        let (firstCount, chunks) = lock.withLock { (firstBufferCount, deliveredChunks) }
        #expect(firstCount == 1)
        #expect(!chunks.isEmpty)
        #expect(chunks[0].count == 2_400)
        #expect(chunks[0] == Array(samples.prefix(2_400)))
    }

    @Test func fastPacingEmitsZeroesAfterAudioEnds() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samples = makeSineSamples()
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1)
        let wavURL = tempDir.appendingPathComponent("sine24k_fast.wav")
        try wavData.write(to: wavURL)

        let recorder = WAVInjectedRecorder(url: wavURL, pace: 0.1)
        let lock = NSLock()
        var deliveredChunks: [[Int16]] = []

        recorder.onPCMChunk = { chunk in
            lock.withLock { deliveredChunks.append(chunk) }
        }

        try recorder.start()

        // 8,400 samples = 3 full chunks (7,200) + 1 partial chunk (1,200 samples + 1,200 zeros).
        // Chunks 5+ (index 4+) should be completely all-zero.
        let start = DispatchTime.now()
        while DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 1_000_000_000 {
            let count = lock.withLock { deliveredChunks.count }
            if count >= 6 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = recorder.stop()

        let chunks = lock.withLock { deliveredChunks }
        #expect(chunks.count >= 6)
        // Chunks beyond 0.35 s of audio must be all-zero
        for i in 4..<chunks.count {
            #expect(chunks[i].count == 2_400)
            #expect(chunks[i].allSatisfy { $0 == 0 })
        }
    }

    @Test func stopReturnsSamplesAndStateLifecycle() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samples = makeSineSamples()
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1)
        let wavURL = tempDir.appendingPathComponent("sine24k_stop.wav")
        try wavData.write(to: wavURL)

        let recorder = WAVInjectedRecorder(url: wavURL, pace: 0.1)
        try recorder.start()
        #expect(recorder.isRunning == true)
        #expect(recorder.isAllocated == true)

        let start = DispatchTime.now()
        while DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 1_000_000_000 {
            if !recorder.isRunning { break }
            try await Task.sleep(nanoseconds: 60_000_000)
            break
        }

        let stoppedSamples = recorder.stop()
        #expect(stoppedSamples.count >= 8_400)
        #expect(abs(stoppedSamples[0] - Float(samples[0]) / 32768.0) < 1e-4)
        #expect(recorder.isRunning == false)

        recorder.release()
        #expect(recorder.isAllocated == false)
    }

    @Test func invalidFormatOrMissingFileThrows() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samples = makeSineSamples()

        // 16 kHz WAV
        let wav16kData = WAVEncoder.encode(samples: samples, sampleRate: 16_000, channels: 1)
        let wav16kURL = tempDir.appendingPathComponent("sine16k.wav")
        try wav16kData.write(to: wav16kURL)

        let rec16k = WAVInjectedRecorder(url: wav16kURL)
        #expect(throws: AudioRecorder.RecorderError.noInput) {
            try rec16k.start()
        }

        // Missing path
        let missingURL = tempDir.appendingPathComponent("missing.wav")
        let recMissing = WAVInjectedRecorder(url: missingURL)
        #expect(throws: AudioRecorder.RecorderError.noInput) {
            try recMissing.start()
        }
    }

    // Host order (archie-v32 "So So" run): tap() pre-starts with no transcriber attached, then
    // start() resets the boundary and attaches. The WAV must reach the transcriber exactly once.
    @Test func preStartThenBoundaryDeliversTheWAVOnce() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samples = makeSineSamples(duration: 1.0)
        let wavURL = tempDir.appendingPathComponent("sine24k.wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1).write(to: wavURL)
        let recorder = WAVInjectedRecorder(url: wavURL, pace: 1.0)
        let lock = NSLock()
        var delivered: [Int16] = []

        try recorder.start()                                   // first ⌥: pre-start, nothing attached
        try await Task.sleep(nanoseconds: 350_000_000)         // pre-roll plays (≈ "So")
        recorder.resetCapture()                                // ⌥⌥ boundary
        recorder.onPCMChunk = { chunk in lock.withLock { delivered.append(contentsOf: chunk) } }
        try recorder.start()                                   // already running: must not restart
        for _ in 0..<300 where lock.withLock({ delivered.count < samples.count }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = recorder.stop()

        let got = lock.withLock { delivered }
        #expect(got.count >= samples.count)
        #expect(Array(got.prefix(samples.count)) == samples)   // starts at sample 0, no pre-roll repeat
        #expect(got.dropFirst(samples.count).allSatisfy { $0 == 0 })   // only silence padding after the WAV
    }

    // v1.7 H1: headset = digital zeros, built-in = the WAV, through the production CaptureFeed.
    @Test func headsetZerosScenarioKeepsTheBuiltinAndDeliversTheWAVOnce() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samples = makeSineSamples(duration: 2.5)
        let wavURL = tempDir.appendingPathComponent("sine24k.wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1).write(to: wavURL)
        let recorder = WAVInjectedRecorder(url: wavURL, pace: 0.05, scenario: .headsetZeros)
        let lock = NSLock()
        var delivered: [Int16] = []
        var notes: [String] = []
        recorder.note = { line in lock.withLock { notes.append(line) } }   // never the process-wide sink
        recorder.onPCMChunk = { chunk in lock.withLock { delivered.append(contentsOf: chunk) } }
        try recorder.start()
        recorder.resetCapture()
        for _ in 0..<400 where lock.withLock({ delivered.count < samples.count + 4_800 }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = recorder.stop()
        let got = lock.withLock { delivered }
        #expect(Array(got.prefix(samples.count)) == samples)                  // built-in carried every frame
        #expect(got.dropFirst(samples.count).allSatisfy { $0 == 0 })
        #expect(recorder.stats.bridgeSource == "builtin_fallback")
        #expect(recorder.stats.bridgeReason == "headset_digital_silence")
        #expect(recorder.stats.headsetRestart == "still_silent")
        #expect(lock.withLock { notes }.contains("bridge_src=builtin_fallback reason=headset_digital_silence"))
        #expect(WAVInjectedRecorder.scenario(environment: ["DICTATE_INJECT_SCENARIO": "headset_zeros"]) == .headsetZeros)
        #expect(WAVInjectedRecorder.scenario(environment: [:]) == .plain)
    }

    @Test func dictationEngineConstructsWithInjectedAudioURL() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samples = makeSineSamples()
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1)
        let wavURL = tempDir.appendingPathComponent("sine24k.wav")
        try wavData.write(to: wavURL)

        let engine = DictationEngine(
            keyStore: KeyStore(),
            paths: AppPaths(home: tempDir),
            surface: .none,
            injectedAudioURL: wavURL
        )
        #expect(engine.surface == .none)
    }

    // Never setenv in tests: parallel suites read ProcessInfo.environment concurrently.
    @Test func envDictateInjectWAVResolves() {
        let explicit = URL(fileURLWithPath: "/tmp/explicit.wav")
        #expect(AppController.injectedAudioURL(nil, environment: ["DICTATE_INJECT_WAV": "/tmp/env.wav"])?.path == "/tmp/env.wav")
        #expect(AppController.injectedAudioURL(explicit, environment: ["DICTATE_INJECT_WAV": "/tmp/env.wav"]) == explicit)
        #expect(AppController.injectedAudioURL(nil, environment: ["DICTATE_INJECT_WAV": ""]) == nil)
        #expect(AppController.injectedAudioURL(nil, environment: [:]) == nil)
    }

    // AppController/CaptureLifecycle expect first-buffer and level on main, like AudioRecorder.
    @Test func firstBufferAndLevelOnMainWithInjectSource() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let wavURL = tempDir.appendingPathComponent("sine24k.wav")
        try WAVEncoder.encode(samples: makeSineSamples(), sampleRate: 24_000, channels: 1).write(to: wavURL)
        let recorder = WAVInjectedRecorder(url: wavURL, pace: 1.0)
        #expect(recorder.stats.bridgeSource == "inject")
        var firstOnMain: Bool?
        var levelOnMain: Bool?
        recorder.onFirstBuffer = { firstOnMain = Thread.isMainThread }
        recorder.onLevel = { _ in levelOnMain = levelOnMain ?? Thread.isMainThread }
        try recorder.start()
        for _ in 0..<100 where firstOnMain == nil || levelOnMain == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = recorder.stop()
        #expect(firstOnMain == true)
        #expect(levelOnMain == true)
    }

    // A failed start (bad file) must not leave the lock held: the controller reads isRunning next.
    @Test func failedStartReleasesTheLock() throws {
        let recorder = WAVInjectedRecorder(url: URL(fileURLWithPath: "/nonexistent/missing.wav"))
        #expect(throws: AudioRecorder.RecorderError.self) { try recorder.start() }
        let done = DispatchSemaphore(value: 0)
        let box = LockedResult()
        Thread.detachNewThread { box.value = recorder.isRunning; done.signal() }
        #expect(done.wait(timeout: .now() + 1) == .success, "isRunning deadlocked after a failed start")
        #expect(box.value == false)
    }

    // WAVE_FORMAT_EXTENSIBLE (tag 0xFFFE, as afconvert/the real fixture write) with the PCM subformat.
    @Test func extensiblePCMParsesAndFloatSubformatThrows() throws {
        func extensible(subformatFirstByte: UInt8, samples: [Int16]) -> Data {
            var d = Data()
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(4 + 48 + 8 + samples.count * 2))
            d.append(contentsOf: Array("WAVE".utf8)); d.append(contentsOf: Array("fmt ".utf8)); u32(40)
            u16(0xFFFE); u16(1); u32(24_000); u32(48_000); u16(2); u16(16); u16(22); u16(16); u32(4)
            d.append(contentsOf: [subformatFirstByte, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                                  0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71])
            d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
            for v in samples { u16(UInt16(bitPattern: v)) }
            return d
        }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pcm = dir.appendingPathComponent("ext-pcm.wav"), float = dir.appendingPathComponent("ext-float.wav")
        try extensible(subformatFirstByte: 0x01, samples: [1, -2, 3]).write(to: pcm)
        try extensible(subformatFirstByte: 0x03, samples: [1, -2, 3]).write(to: float)
        #expect(try WAVInjectedRecorder.parseWAV(at: pcm) == [1, -2, 3])
        #expect(throws: AudioRecorder.RecorderError.self) { try WAVInjectedRecorder.parseWAV(at: float) }
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
