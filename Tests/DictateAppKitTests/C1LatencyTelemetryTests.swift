import Foundation
import Testing
@testable import DictateAppKit

@Suite
struct C1LatencyTelemetryTests {
    @Test func startupFieldsTravelWithActualProcessingState() {
        for state in ["on", "off", "unavailable"] {
            var stats = AudioRecorder.CaptureStats()
            stats.engineStartMs = 17
            stats.firstBufferMs = 23
            stats.voiceProcessing = state
            let fields = "engine_start_ms=17 first_buffer_ms=23 voice_processing=\(state)"
            #expect(stats.startupFields == fields)
            #expect(stats.sessionEndFields.contains(fields))
        }
        #expect(AudioRecorder.CaptureStats().startupFields == "engine_start_ms=0 first_buffer_ms=- voice_processing=off")
        print("C1 LATENCY live=unmeasured logged_fields=engine_start_ms,first_buffer_ms,voice_processing")
    }
    @Test func nativeRefusalRemainsUnavailableEvenIfFallbackFails() {
        struct StartFailed: Error {}
        let recorder = C1VoiceProcessingTests().recorder()
        #expect(throws: StartFailed.self) {
            try recorder.startCaptureInput { _ in
                CaptureInputUnit(start: { throw StartFailed() }, dispose: {})
            }
        }
        #expect(recorder.stats.voiceProcessing == "unavailable")
        #expect(recorder.stats.startupFields.contains("voice_processing=unavailable"))
    }
}
