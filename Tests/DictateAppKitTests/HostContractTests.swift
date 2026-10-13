import Testing
import DictateCore
import DictateAppKit   // NOT @testable: only what a host (Archie v40) can see

/// v1.11 L2: the capture contract Archie v40's ⌘⌘ path consumes, frozen at compile time. Changing
/// any of these members' names or types breaks this file before it can break the host. No audio:
/// the recorder is constructed (device-free) and its members are referenced, never started.
@Suite("HostContract")
struct HostContractTests {
    @Test func audioRecorderHostContract() {
        let recorder: AudioRecorder = AudioRecorder()
        // 24 kHz mono pcm16, 100 ms chunks, in order.
        #expect(AudioRecorder.sampleRate == 24_000)
        #expect(AudioRecorder.chunkSamples == 2_400)
        let pcm: (([Int16]) -> Void)? = recorder.onPCMChunk
        #expect(pcm == nil)
        recorder.onPCMChunk = { (_: [Int16]) in }
        let failure: ((CaptureFailure) -> Void)? = recorder.onCaptureFailure
        #expect(failure == nil)
        recorder.onCaptureFailure = { (_: CaptureFailure) in }
        let reset: () -> Void = recorder.resetCapture
        let start: (MicChoice) async throws -> Void = recorder.startAsync(device:)
        let stop: () -> [Float] = recorder.stop
        _ = (reset, start, stop)
        let stats: AudioRecorder.CaptureStats = recorder.stats
        let bridgeSource: String = stats.bridgeSource
        let bridgeMs: Int? = stats.bridgeMs
        let ioOps: String = stats.ioOps
        let ioHeld: String = stats.ioHeld
        let speechSections: Int = stats.speechSections
        let recordingMs: Int = stats.recordingMs
        #expect(bridgeSource == "none" && bridgeMs == nil && speechSections == 0 && recordingMs == 0)
        #expect(ioOps.hasPrefix("io_ops=") && ioHeld.hasPrefix("io_held="))
        recorder.onPCMChunk = nil
        recorder.onCaptureFailure = nil
    }

    /// v1.11 L2: a host labels its session; the session-end fields carry it (default dictation).
    @Test func sessionKindIsAHostLabel() {
        let recorder = AudioRecorder()
        #expect(recorder.kind == .dictation)
        recorder.kind = .conversation
        #expect(recorder.kind == .conversation)
        #expect(CaptureKind(rawValue: "conversation") == .conversation && CaptureKind.dictation.rawValue == "dictation")
        var stats = AudioRecorder.CaptureStats()
        #expect(stats.kind == .dictation)
        stats.kind = .conversation
        let fields: String = stats.sessionEndFields
        #expect(fields.hasPrefix("kind=conversation recording_ms=0 capture_intervals=none speech_sections=0"))
        #expect(fields.contains(" carrier=none headset_carried_ms=0 io_ops="))
    }
}
