import AVFoundation
import DictateCore
import Foundation
import Testing
@testable import DictateAppKit

@Suite(.serialized)
struct C1VoiceProcessingTests {
    // The injected factory is the ONLY path started here. No AVAudioEngine,
    // HAL/VPIO instance, microphone, audio output, or system route queries.
    func recorder(input: CaptureBridge.DefaultInput = .builtin, outputBluetooth: Bool? = false,
                  kind: CaptureKind = .conversation) -> AudioRecorder {
        let log = CaptureLeaseRecorderTests.Log()
        let recorder = AudioRecorder(builtin: { CaptureLeaseRecorderTests.FakeBuiltin("builtin", log) },
            broker: CaptureLeaseBroker(), route: CaptureRouteProbe(eligibility: { (input, true) },
                defaultInput: { 81 }, uid: { _ in "fixture" }, defaultInputName: { "fixture" },
                outputIsBluetooth: { outputBluetooth }))
        recorder.kind = kind
        return recorder
    }
    @Test func builtInConversationUsesVPIOAndMinimumDucking() throws {
        let conversation = recorder()
        var made: [CaptureVoiceProcessing.Unit] = []
        var configured = false, started = false
        try conversation.startCaptureInput { mode in
            made.append(mode)
            return CaptureInputUnit(start: { started = true; #expect(configured) }, dispose: {}, configure: { ducking in
                #expect(!ducking.enableAdvancedDucking.boolValue)
                #expect(ducking.duckingLevel == .min)
                configured = true
            })
        }
        #expect(made == [.vpio] && started && configured)
        #expect(conversation.stats.voiceProcessing == "on")
        let dictation = recorder(kind: .dictation)
        var dictationUnit: CaptureVoiceProcessing.Unit?
        try dictation.startCaptureInput { mode in
            dictationUnit = mode
            return CaptureInputUnit(start: {}, dispose: {}, configure: { _ in Issue.record("dictation enabled VPIO") })
        }
        #expect(dictationUnit == .halout && dictation.stats.voiceProcessing == "off")
        let bluetooth = recorder(input: .bluetooth)
        var bluetoothUnit: CaptureVoiceProcessing.Unit?
        try bluetooth.startCaptureInput { mode in
            bluetoothUnit = mode
            return CaptureInputUnit(start: {}, dispose: {}, configure: { _ in Issue.record("Bluetooth enabled VPIO") })
        }
        #expect(bluetoothUnit == .halout && bluetooth.stats.voiceProcessing == "unavailable")
        // Same real per-buffer converter the VPIO nil-format tap calls.
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        input.frameLength = 4_800
        for ch in 0..<2 {
            for i in 0..<4_800 { input.floatChannelData![ch][i] = Float(sin(2 * .pi * 220 * Double(i) / 48_000) * 0.1) }
        }
        var delivered: [[Float]] = []
        conversation.headsetNative.converted = { delivered.append($0) }
        conversation.offlineHeadsetBuffer(input)
        conversation.offlineHeadsetBuffer(input)
        #expect(!delivered.isEmpty)
        // Per-callback converter allocation is b74b068's (budget + 32); AudioRecorder re-chunks the
        // pcm16 stream to `chunkSamples` downstream. Frames the resampler holds back are not lost:
        // after an end-of-stream flush the two callbacks yield exactly 2 x 2 400 frames.
        #expect(delivered.allSatisfy { !$0.isEmpty && $0.count <= 2_400 + 32 })
        #expect(delivered.flatMap { $0 }.count + (try conversation.offlineFlushConverter()).count == 4_800)
        #expect(delivered.flatMap { $0 }.contains { abs($0) > 0.01 })
        #expect(AudioRecorder.sampleRate == 24_000 && AudioRecorder.chunkSamples == 2_400)
        print("C1 GREEN wiring unit=vpio ducking=min format_out=24000Hz/1ch/pcm16 dictation_unit=halout bluetooth_unit=unchanged")
    }
    @Test func refusalDisposesBeforeLegacyCaptureAndKeepsCapturing() throws {
        for reason in ["enable_refused", "ducking_refused", "start_refused"] {
            var events: [String] = [], notes: [String] = []
            let state = try CaptureVoiceProcessing.start(requested: true, builtin: true, bluetooth: false, make: { mode in
                events.append("make_\(mode.rawValue)")
                return CaptureInputUnit(start: {
                    events.append("start_\(mode.rawValue)")
                    if mode == .vpio, reason == "start_refused" { throw CaptureVoiceProcessing.Refusal(reason: reason) }
                }, dispose: { events.append("dispose") }, configure: { _ in
                    events.append("configure_vpio")
                    if reason != "start_refused" { throw CaptureVoiceProcessing.Refusal(reason: reason) }
                })
            }, note: { notes.append($0) })
            #expect(state == .unavailable)
            let expected = reason == "start_refused"
                ? ["make_vpio", "configure_vpio", "start_vpio", "dispose", "make_halout", "start_halout"]
                : ["make_vpio", "configure_vpio", "dispose", "make_halout", "start_halout"]
            #expect(events == expected)
            #expect(notes == ["voice_processing=unavailable reason=\(reason)"])
            print("C1 CONTROL refused \(notes[0]) fallback=halout capture_ok=1")
        }
    }
    @Test func ineligibleRoutesNeverConstructVPIO() throws {
        for (input, output) in [(CaptureBridge.DefaultInput.builtin, true as Bool?), (.builtin, nil), (.other, false)] {
            let r = recorder(input: input, outputBluetooth: output)
            try r.startCaptureInput { mode in
                #expect(mode == .halout)
                return CaptureInputUnit(start: {}, dispose: {})
            }
            #expect(r.stats.voiceProcessing == "unavailable")
        }
    }
    /// Raza's headset often falls back to the BUILT-IN mic while OUTPUT stays on the Bluetooth headset
    /// (`headset_digital_silence`). VPIO opens the output side too (AVAudioIONode: "Enabling this mode
    /// on either of the IO nodes automatically enables it on the other IO node") and was the prime
    /// suspect for the WH-1000XM6 silent output, so a Bluetooth output alone keeps today's HAL path —
    /// Archie's `shouldUseVoiceProcessing` rule (false when EITHER side is Bluetooth).
    @Test func bluetoothOutputWithBuiltInInputKeepsTodaysPath() throws {
        final class Notes: @unchecked Sendable { let lock = NSLock(); var lines: [String] = [] }
        let notes = Notes()
        AppController.setNoteSink { line in notes.lock.withLock { notes.lines.append(line) } }
        defer { AppController.setNoteSink(nil) }
        let r = recorder(input: .builtin, outputBluetooth: true)
        var made: [CaptureVoiceProcessing.Unit] = []
        try r.startCaptureInput { mode in
            made.append(mode)
            return CaptureInputUnit(start: {}, dispose: {}, configure: { _ in Issue.record("Bluetooth output enabled VPIO") })
        }
        let line = try #require(notes.lock.withLock { notes.lines.first { $0.contains("voice_processing=") } })
        #expect(made == [.halout])
        #expect(r.stats.voiceProcessing == "unavailable")
        #expect(line.hasSuffix("voice_processing=unavailable reason=bluetooth_route"))
        print("C1 CONTROL bt_output_builtin_input voice_processing=\(r.stats.voiceProcessing) reason=\(line.components(separatedBy: "reason=").last ?? "-")")
    }
    @Test func fallbackStartFailureStillPropagates() {
        struct Failed: Error {}
        #expect(throws: Failed.self) {
            _ = try CaptureVoiceProcessing.start(requested: true, builtin: true, bluetooth: false, make: { _ in
                CaptureInputUnit(start: { throw Failed() }, dispose: {})
            }, note: { _ in })
        }
    }
}
