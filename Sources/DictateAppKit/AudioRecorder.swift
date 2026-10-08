import AVFoundation
import DictateCore

/// AVAudioEngine capture, converted live to 24 kHz mono (the rate the batch STT fallbacks
/// pcm16 rate) and kept in memory only. Nothing is ever written to disk.
public final class AudioRecorder {
    public static let sampleRate: Double = 24_000
    /// 100 ms of pcm16 per streamed chunk (v1.1 A1).
    public static let chunkSamples = 2_400

    /// Called on the main queue with a 0...1 level, ~30 times a second.
    public var onLevel: ((Float) -> Void)?
    /// Called on the AUDIO thread with each 100 ms pcm16 chunk, and once more
    /// from `stop()` with the remainder. Must be thread-safe.
    public var onPCMChunk: (([Int16]) -> Void)?
    private var pendingPCM: [Int16] = []

    /// What the capture did, for the per-dictation stderr timeline.
    public struct CaptureStats {
        public var device = ""
        public var startFormat = ""
        public var engineStartMs = 0
        public var firstBufferMs: Int?
        public var formatChanges = 0
        public var configChanges = 0
    }
    public private(set) var stats = CaptureStats()
    /// Called on the main queue when the first audio buffer arrives after
    /// `start()` (a Bluetooth headset can take ~1.6 s to deliver it).
    public var onFirstBuffer: (() -> Void)?
    public private(set) var isRunning = false
    private var startedAt = DispatchTime.now()
    private var recording = false
    private var configObserver: NSObjectProtocol?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!
    private var lastLevelPost: TimeInterval = 0
    private var meter = LevelMeter()
    private var pendingLevel: Float = 0

    public init() {}

    public static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }

    public func start() throws {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        pendingPCM.removeAll()
        stats = CaptureStats()
        meter = LevelMeter()
        lock.unlock()
        startedAt = DispatchTime.now()
        stats.device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown"
        try installTapAndStart()
        stats.engineStartMs = elapsedMs()
        recording = true
        isRunning = true
        // A Bluetooth headset switches profile (A2DP -> HFP) when its mic opens,
        // which reconfigures the engine mid-recording; re-tap on the new format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.recording else { return }
            self.stats.configChanges += 1
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.installTapAndStart()
        }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        if stats.startFormat.isEmpty {
            stats.startFormat = "\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch"
        }
        lock.withLock { converter = AVAudioConverter(from: inputFormat, to: targetFormat) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func elapsedMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
    }

    /// Stops capture and hands back everything recorded, as 16 kHz mono floats.
    /// Dictation begins on an engine that may already be running (pre-warmed on
    /// the first ⌥ tap): drop the pre-roll so only post-double-tap audio counts.
    public func resetCapture() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            pendingPCM.removeAll()
        }
    }

    public func stop() -> [Float] {
        recording = false
        isRunning = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { converter = nil }
        lock.lock()
        let captured = samples
        let remainder = pendingPCM
        samples.removeAll()
        pendingPCM.removeAll()
        lock.unlock()
        if !remainder.isEmpty { onPCMChunk?(remainder) }
        return captured
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        // The converter must match the buffers actually arriving: a format
        // change under a live tap otherwise yields garbled (resampled-wrong) audio.
        let converter: AVAudioConverter? = lock.withLock {
            if stats.firstBufferMs == nil {
                stats.firstBufferMs = elapsedMs()
                DispatchQueue.main.async { [weak self] in self?.onFirstBuffer?() }
            }
            if let current = self.converter, current.inputFormat == buffer.format { return current }
            if self.converter != nil { stats.formatChanges += 1 }
            self.converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            return self.converter
        }
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        var ready: [[Int16]] = []
        lock.lock()
        samples.append(contentsOf: chunk)
        if onPCMChunk != nil {
            pendingPCM.append(contentsOf: WAVEncoder.pcm16(from: chunk))
            while pendingPCM.count >= AudioRecorder.chunkSamples {
                ready.append(Array(pendingPCM.prefix(AudioRecorder.chunkSamples)))
                pendingPCM.removeFirst(AudioRecorder.chunkSamples)
            }
        }
        lock.unlock()
        for pcm in ready { onPCMChunk?(pcm) }

        // The meter sees every chunk (its peak tracking needs real time); the
        // pill gets the loudest level since its last 30 fps post.
        let seconds = Double(chunk.count) / AudioRecorder.sampleRate
        let now = ProcessInfo.processInfo.systemUptime
        let post: Float? = lock.withLock {
            pendingLevel = max(pendingLevel, meter.level(rms: AudioLevel.rms(chunk), seconds: seconds))
            guard now - lastLevelPost >= 1.0 / 30.0 else { return nil }
            lastLevelPost = now
            defer { pendingLevel = 0 }
            return pendingLevel
        }
        if let post { DispatchQueue.main.async { [weak self] in self?.onLevel?(post) } }
    }

    public enum RecorderError: Error { case noInput }
}
