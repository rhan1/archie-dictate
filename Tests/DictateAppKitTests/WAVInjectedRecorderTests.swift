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

    @Test func envDictateInjectWAVConstructs() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let samples = makeSineSamples()
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 24_000, channels: 1)
        let wavURL = tempDir.appendingPathComponent("env_sine24k.wav")
        try wavData.write(to: wavURL)

        setenv("DICTATE_INJECT_WAV", wavURL.path, 1)
        defer { unsetenv("DICTATE_INJECT_WAV") }

        let engine = DictationEngine(
            keyStore: KeyStore(),
            paths: AppPaths(home: tempDir),
            surface: .none
        )
        #expect(engine.surface == .none)
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
}
