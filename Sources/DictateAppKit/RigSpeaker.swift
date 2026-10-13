import AVFoundation
import CoreAudio
import DictateCore

/// v1.14: the rig's mouth (`DictateBench rig-play`). Plays a 24 kHz mono 16-bit clip through the BUILT-IN
/// output device, bound by its UID on a private AVAudioEngine's output unit, peak-normalised to a fixed
/// dBFS. The system default output device and the system volume are never read for writing, never set.
/// `fake: true` is the dry run's engine: no device is looked up and no AVAudioEngine is ever constructed.
public enum RigSpeaker {
    public struct Result: Sendable {
        public let deviceUID: String
        public let gainDB: Double
        public let peakDBFS: Double
        public let durationMs: Int
        public let enginesOpened: Int
        public let outcome: String
        /// `rig_play device_uid=… gain_db=… peak_dbfs=… duration_ms=… engine_opened=N result=…`
        public var line: String {
            String(format: "rig_play device_uid=%@ gain_db=%.2f peak_dbfs=%.1f duration_ms=%d engine_opened=%d result=%@",
                   deviceUID, gainDB, peakDBFS, durationMs, enginesOpened, outcome)
        }
    }

    /// Every real AVAudioEngine this process constructed for playback (the dry run asserts 0).
    nonisolated(unsafe) public private(set) static var enginesOpened = 0

    public static func play(wav url: URL, levelDBFS: Double, fake: Bool) -> Result {
        let samples: [Int16]
        do { samples = try WAVInjectedRecorder.parseWAV(at: url) } catch {
            return Result(deviceUID: "-", gainDB: 0, peakDBFS: levelDBFS, durationMs: 0, enginesOpened: enginesOpened, outcome: "bad_wav")
        }
        let peak = samples.reduce(Int32(0)) { max($0, abs(Int32($1))) }
        guard peak > 0, levelDBFS <= 0 else {
            return Result(deviceUID: "-", gainDB: 0, peakDBFS: levelDBFS, durationMs: 0, enginesOpened: enginesOpened, outcome: peak > 0 ? "bad_level" : "silent_wav")
        }
        let gain = pow(10, levelDBFS / 20) / (Double(peak) / 32_768)
        let gainDB = 20 * log10(gain)
        let durationMs = Int((Double(samples.count) / 24_000 * 1000).rounded())
        if fake {
            return Result(deviceUID: "fake-builtin", gainDB: gainDB, peakDBFS: levelDBFS, durationMs: durationMs,
                          enginesOpened: enginesOpened, outcome: "ok")
        }
        guard let (device, uid) = builtInOutput() else {
            return Result(deviceUID: "-", gainDB: gainDB, peakDBFS: levelDBFS, durationMs: 0, enginesOpened: enginesOpened, outcome: "no_builtin_output")
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return Result(deviceUID: uid, gainDB: gainDB, peakDBFS: levelDBFS, durationMs: 0, enginesOpened: enginesOpened, outcome: "no_buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (i, s) in samples.enumerated() { channel[i] = Float(Double(s) / 32_768 * gain) }

        let engine = AVAudioEngine()
        enginesOpened += 1
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let started = ContinuousClock.now
        do {
            // Bind THIS engine's output unit to the built-in device; the system default is untouched.
            try engine.outputNode.auAudioUnit.setDeviceID(device)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
        } catch {
            return Result(deviceUID: uid, gainDB: gainDB, peakDBFS: levelDBFS, durationMs: 0, enginesOpened: enginesOpened, outcome: "engine_error")
        }
        let done = DispatchSemaphore(value: 0)
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in done.signal() }
        player.play()
        let finished = done.wait(timeout: .now() + .milliseconds(durationMs + 5_000)) == .success
        player.stop()
        engine.stop()
        let elapsed = started.duration(to: .now)
        let playedMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return Result(deviceUID: uid, gainDB: gainDB, peakDBFS: levelDBFS, durationMs: playedMs, enginesOpened: enginesOpened,
                      outcome: finished ? "ok" : "timeout")
    }

    /// The built-in output (transport built-in, has output streams) and its UID; property reads only.
    static func builtInOutput() -> (AudioDeviceID, String)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard devices.withUnsafeMutableBytes({
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }) == noErr else { return nil }
        for device in devices {
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var type = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &type, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = AudioDevices.uid(of: device) else { continue }
            return (device, uid)
        }
        return nil
    }
}
