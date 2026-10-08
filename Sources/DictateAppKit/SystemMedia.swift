import AppKit
import CoreAudio
import DictateCore

/// Real `MediaControl`: which apps are producing audio (CoreAudio process
/// objects, read-only), plus MediaRemote's now-playing flag as an extra
/// positive signal, and the play/pause media key. Never touches volume or mute.
final class SystemMedia: MediaControl {
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private let mediaRemoteIsPlaying: IsPlayingFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else { return nil }
        return unsafeBitCast(symbol, to: IsPlayingFn.self)
    }()

    func playingSources() -> Set<String>? {
        var sources = Set<String>()
        let coreAudio = processesRunningOutput()
        if let coreAudio { sources.formUnion(coreAudio) }
        // macOS 15.4+ withholds now-playing info from third-party apps (measured
        // here: isPlaying=false, info nil while Chrome played), so MediaRemote can
        // only ever ADD a positive signal, never prove silence.
        if mediaRemoteNowPlaying() == true { sources.insert("com.apple.mediaremote.nowplaying") }
        return coreAudio == nil && sources.isEmpty ? nil : sources
    }

    func togglePlayPause() {
        postMediaKey(down: true)
        postMediaKey(down: false)
    }

    // NX_KEYTYPE_PLAY = 16, posted as a systemDefined event, subtype 8.
    private func postMediaKey(down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let data1 = (16 << 16) | ((down ? 0xA : 0xB) << 8)
        let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    private func mediaRemoteNowPlaying() -> Bool? {
        guard let query = mediaRemoteIsPlaying else { return nil }
        var result: Bool?
        let done = DispatchSemaphore(value: 0)
        query(DispatchQueue.global()) { playing in
            result = playing
            done.signal()
        }
        return done.wait(timeout: .now() + 0.3) == .success ? result : nil
    }

    private func processesRunningOutput() -> Set<String>? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        var running = Set<String>()
        for id in ids {
            var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var isRunning: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &outputAddress, 0, nil, &valueSize, &isRunning) == noErr, isRunning != 0 else { continue }
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr, let bundle {
                running.insert(bundle.takeRetainedValue() as String)
            }
        }
        return running
    }
}
