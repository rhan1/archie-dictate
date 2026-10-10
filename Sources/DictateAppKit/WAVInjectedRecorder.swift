import Foundation
import DictateCore

/// Replaces the microphone with a 24 kHz mono 16-bit WAV for unattended end-to-end runs:
/// 100 ms chunks paced in real time, then silence until stop(). Timeline: `bridge_src=inject`.
public final class WAVInjectedRecorder: EngineRecorder {
    public let url: URL
    public let pace: Double

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

    public init(url: URL, pace: Double = 1.0) {
        self.url = url
        self.pace = max(0.0001, pace)
        var s = AudioRecorder.CaptureStats()
        s.device = "injected:\(url.lastPathComponent)"
        s.startFormat = "24000Hz/1ch"
        s.bridgeSource = "inject"
        self.stats = s
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

        let floatChunk = chunk.map { Float($0) / 32768.0 }
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

        // Same threads as AudioRecorder: PCM from the capture queue, first-buffer and level on main.
        pcmCb?(chunk)
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
        lock.unlock()
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
        }
    }
}
