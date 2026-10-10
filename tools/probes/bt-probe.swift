// BT1 probe: prints, every 0.5 s, the default output device's nominal sample rate
// and whether the default input device is running anywhere (an open mic keeps a
// Bluetooth headset in the hands-free profile: 16 kHz mono, poor music quality).
//   swift tools/probes/bt-probe.swift [seconds=20]
import CoreAudio
import Foundation

func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
}
func device(_ sel: AudioObjectPropertySelector) -> AudioObjectID {
    var id = AudioObjectID(0); _ = prop(AudioObjectID(kAudioObjectSystemObject), sel, kAudioObjectPropertyScopeGlobal, &id); return id
}
func name(_ id: AudioObjectID) -> String {
    var cf: CFString = "" as CFString; _ = prop(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, &cf); return cf as String
}
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let start = Date()
while Date().timeIntervalSince(start) < seconds {
    let out = device(kAudioHardwarePropertyDefaultOutputDevice), inp = device(kAudioHardwarePropertyDefaultInputDevice)
    var rate = Float64(0); _ = prop(out, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate)
    var running = UInt32(0); _ = prop(inp, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, &running)
    var outRunning = UInt32(0); _ = prop(out, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, &outRunning)
    print(String(format: "t=%5.1f out=\"%@\" out_rate=%.0f out_running=%d in=\"%@\" in_running=%d", Date().timeIntervalSince(start), name(out), rate, outRunning, name(inp), running))
    fflush(stdout)
    Thread.sleep(forTimeInterval: 0.5)
}
