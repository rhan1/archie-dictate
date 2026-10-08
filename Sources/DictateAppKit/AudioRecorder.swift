import AVFoundation
import DictateCore

/// AVAudioEngine capture, converted live to 24 kHz mono (the Realtime API's
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

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!
    private var lastLevelPost: TimeInterval = 0

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
        lock.lock(); samples.removeAll(keepingCapacity: true); pendingPCM.removeAll(); lock.unlock()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture and hands back everything recorded, as 16 kHz mono floats.
    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
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

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelPost >= 1.0 / 30.0 {
            lastLevelPost = now
            let level = AudioLevel.normalized(rms: AudioLevel.rms(chunk))
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }
    }

    public enum RecorderError: Error { case noInput }
}
