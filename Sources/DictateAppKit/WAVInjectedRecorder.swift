import Foundation
import DictateCore

/// Replaces the microphone with a 24 kHz mono 16-bit WAV for unattended end-to-end runs:
/// 100 ms chunks paced in real time, then silence until stop(). Timeline: `bridge_src=inject`.
///
/// Scenario `headsetZeros` (v1.7, `DICTATE_INJECT_SCENARIO=headset_zeros`): the WAV is the
/// built-in microphone and a Bluetooth headset delivers only digital zeros (a dropped eSCO
/// link); both run through the production CaptureFeed arbitration.
public final class WAVInjectedRecorder: EngineRecorder {
    public enum Scenario: String, Sendable { case plain, headsetZeros = "headset_zeros" }
    public let url: URL
    public let pace: Double
    public let scenario: Scenario
    /// Diagnostics sink (the engine's notes by default); tests keep their notes local.
    public var note: (String) -> Void = { AppController.note($0) }

    public var onLevel: ((Double) -> Void)?
    public var onPCMChunk: (([Int16]) -> Void)?
    public var onFirstBuffer: (() -> Void)?
    public var onCaptureFailure: (() -> Void)?

    public private(set) var stats: AudioRecorder.CaptureStats
    public var bridgeHasAudio: Bool { false }

    public var isRunning: Bool { lock.withLock { timer != nil } }
    public var isAllocated: Bool { lock.withLock { timer != nil } }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dictate.capture.injected")
    private var timer: DispatchSourceTimer?
    private var wavSamples: [Int16] = []
    private var sampleCursor: Int = 0
    private var buffer: [Float] = []
    private var firstBufferFired: Bool = false
    private var meter = WisprLevel()
    private var feed = CaptureFeed()
    private var pendingPCM: [Int16] = []
    /// Media clock of the scenario feed: 0.1 s per chunk whatever the pace.
    private var mediaTime: TimeInterval = 0

    public init(url: URL, pace: Double = 1.0, scenario: Scenario = .plain) {
        self.url = url
        self.pace = max(0.0001, pace)
        self.scenario = scenario
        var s = AudioRecorder.CaptureStats()
        s.device = "injected:\(url.lastPathComponent)"
        s.startFormat = "24000Hz/1ch"
        s.bridgeSource = "inject"
        self.stats = s
    }

    /// The scenario named by `DICTATE_INJECT_SCENARIO`; plain when unset or unknown.
    public static func scenario(environment: [String: String]) -> Scenario {
        environment["DICTATE_INJECT_SCENARIO"].flatMap(Scenario.init(rawValue:)) ?? .plain
    }

    public static func parseWAV(at url: URL) throws -> [Int16] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AudioRecorder.RecorderError.noInput
        }
        guard data.count >= 12,
              data.starts(with: "RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8) else {
            throw AudioRecorder.RecorderError.noInput
        }

        var foundFmt = false
        var pcmSamples: [Int16] = []
        var offset = 12

        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data[offset + 4]) |
                       (Int(data[offset + 5]) << 8) |
                       (Int(data[offset + 6]) << 16) |
                       (Int(data[offset + 7]) << 24)
            guard size >= 0 else { throw AudioRecorder.RecorderError.noInput }
            let chunkStart = offset + 8
            let chunkEnd = min(data.count, chunkStart + size)

            if id == "fmt " {
                guard size >= 16, chunkEnd - chunkStart >= 16 else {
                    throw AudioRecorder.RecorderError.noInput
                }
                let format = UInt16(data[chunkStart]) | (UInt16(data[chunkStart + 1]) << 8)
                let channels = UInt16(data[chunkStart + 2]) | (UInt16(data[chunkStart + 3]) << 8)
                let rate = UInt32(data[chunkStart + 4]) |
                           (UInt32(data[chunkStart + 5]) << 8) |
                           (UInt32(data[chunkStart + 6]) << 16) |
                           (UInt32(data[chunkStart + 7]) << 24)
                let bits = UInt16(data[chunkStart + 14]) | (UInt16(data[chunkStart + 15]) << 8)
                // WAVE_FORMAT_EXTENSIBLE (0xFFFE, what afconvert writes) counts as PCM when its
                // subformat GUID is KSDATAFORMAT_SUBTYPE_PCM (00000001-0000-0010-8000-00aa00389b71).
                let pcmGUID: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71]
                let isPCM = format == 1 || (format == 0xFFFE && size >= 40 && chunkEnd - chunkStart >= 40
                    && Array(data[(chunkStart + 24)..<(chunkStart + 40)]) == pcmGUID)
                guard isPCM, channels == 1, rate == 24_000, bits == 16 else {
                    throw AudioRecorder.RecorderError.noInput
                }
                foundFmt = true
            } else if id == "data" {
                pcmSamples.reserveCapacity((chunkEnd - chunkStart) / 2)
                var i = chunkStart
                while i + 1 < chunkEnd {
                    pcmSamples.append(Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8)))
                    i += 2
                }
            }
            offset += 8 + size + (size & 1)
        }

        guard foundFmt else {
            throw AudioRecorder.RecorderError.noInput
        }
        return pcmSamples
    }

    public func start(device: MicChoice = .default) throws {
        // Parse before taking the lock: a throw must never leave it held (isRunning is read next).
        let parsed = try Self.parseWAV(at: url)
        lock.lock()
        if timer != nil {
            lock.unlock()
            return
        }
        wavSamples = parsed
        sampleCursor = 0
        firstBufferFired = false
        buffer.removeAll()
        meter.clearBatch()
        pendingPCM.removeAll()
        if scenario == .headsetZeros {
            feed.start(defaultInput: .bluetooth, hasBuiltin: true)
            mediaTime = 1_000
            _ = feed.recordingStarted(at: mediaTime, preRoll: 0)
        }

        let timerSource = DispatchSource.makeTimerSource(queue: queue)
        let intervalSeconds = 0.1 * pace
        let intervalNs = max(1_000, Int((intervalSeconds * 1_000_000_000).rounded()))
        timerSource.schedule(deadline: .now() + .nanoseconds(intervalNs), repeating: .nanoseconds(intervalNs))
        timerSource.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timerSource
        timerSource.resume()
        lock.unlock()
    }

    public func startAsync(device: MicChoice = .default) async throws {
        try start(device: device)
    }

    private func tick() {
        lock.lock()
        guard timer != nil else {
            lock.unlock()
            return
        }

        var chunk = [Int16]()
        chunk.reserveCapacity(AudioRecorder.chunkSamples)
        if sampleCursor < wavSamples.count {
            let remaining = wavSamples.count - sampleCursor
            if remaining >= AudioRecorder.chunkSamples {
                chunk = Array(wavSamples[sampleCursor..<(sampleCursor + AudioRecorder.chunkSamples)])
                sampleCursor += AudioRecorder.chunkSamples
            } else {
                chunk = Array(wavSamples[sampleCursor..<wavSamples.count])
                sampleCursor = wavSamples.count
                chunk.append(contentsOf: repeatElement(0, count: AudioRecorder.chunkSamples - chunk.count))
            }
        } else {
            chunk = [Int16](repeating: 0, count: AudioRecorder.chunkSamples)
        }

        var floatChunk = chunk.map { Float($0) / 32768.0 }
        var notes: [String] = []
        if scenario == .headsetZeros {
            // Built-in = the WAV, headset = digital zeros, same 100 ms window.
            let time = mediaTime
            mediaTime += Double(chunk.count) / AudioRecorder.sampleRate
            let builtin = feed.accept(floatChunk, source: .builtin, at: time)
            let headset = feed.accept([Float](repeating: 0, count: chunk.count), source: .headset, at: time)
            for out in [builtin, headset] {
                if out.event == .fallback { notes.append("bridge_src=builtin_fallback reason=headset_digital_silence") }
                if out.event == .switchback { notes.append("bridge_switchback=1") }
                if out.restartHeadset { feed.headsetRestarted(); notes.append("headset_restart=1 simulated=1") }
            }
            floatChunk = builtin.frames + headset.frames
            // Exact inverse of the /32768 above: the WAV's samples arrive unchanged.
            pendingPCM += floatChunk.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) }
            let whole = pendingPCM.count / AudioRecorder.chunkSamples * AudioRecorder.chunkSamples
            chunk = Array(pendingPCM.prefix(whole))
            pendingPCM.removeFirst(whole)
        }
        buffer.append(contentsOf: floatChunk)

        let shouldFireFirst = !firstBufferFired
        if shouldFireFirst {
            firstBufferFired = true
        }

        let db = WisprLevel.db(samples: floatChunk)
        let level = meter.level(db: db)

        let firstCb = shouldFireFirst ? onFirstBuffer : nil
        let pcmCb = onPCMChunk
        let levelCb = onLevel
        lock.unlock()

        let sink = note
        for line in notes { sink(line) }
        // Same threads as AudioRecorder: PCM from the capture queue, first-buffer and level on main.
        if !chunk.isEmpty { pcmCb?(chunk) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }   // dropped after stop(), like the real epoch check
            firstCb?()
            levelCb?(level)
        }
    }

    @discardableResult public func stop() -> [Float] {
        lock.lock()
        if let t = timer {
            t.setEventHandler(handler: nil)
            t.cancel()
            timer = nil
        }
        let captured = buffer
        buffer.removeAll()
        firstBufferFired = false
        var remainder: [Int16] = []
        if scenario == .headsetZeros, feed.bridge.state != .off {
            stats.bridgeSource = feed.bridge.bridgeSource
            stats.bridgeReason = feed.bridge.reason
            stats.headsetRestart = feed.bridge.restart?.result
            stats.bridgeSwitchback = feed.bridge.switchbacks
            feed.cancel()
            remainder = pendingPCM
            pendingPCM.removeAll()
        }
        let pcmCb = onPCMChunk
        lock.unlock()
        if !remainder.isEmpty { pcmCb?(remainder) }
        return captured
    }

    public func release() {
        _ = stop()
    }

    public func rebuild() throws {}

    public func rebuildAsync() async throws {}

    public func resetCapture() {
        lock.withLock {
            buffer.removeAll(keepingCapacity: true)
            sampleCursor = 0
            firstBufferFired = false
            meter.clearBatch()
            pendingPCM.removeAll()
            if scenario == .headsetZeros {
                _ = feed.recordingStarted(at: mediaTime, preRoll: 0)
            }
        }
    }
}
