# Conversation capture voice processing (C1)

Status: native wiring, offline AEC-model gate and latency telemetry passed;
regression controls pending. The Archie companion report documents the playback/capture
timeline and unchanged RED/GREEN fixture.

`AudioRecorder.kind = .conversation` opts a built-in, non-Bluetooth input into
Apple voice processing. The default built-in path uses AVAudioEngine's input
node, so it calls `setVoiceProcessingEnabled(true)` before installing a tap.
The raw BuiltinCaptureUnit is the Bluetooth fallback bridge and stays AUHAL.
Bluetooth input or output bypasses VPIO; unknown output transport and other
input routes also conservatively decline it. Dictation never enables it:
there is no expected dictation echo source, and AGC would change W3/STT levels.

Advanced ducking is disabled and other-audio ducking is `.min`, with readback.
A failed enable, ducking configuration or start discards the processed graph
and starts a fresh legacy graph; failure of the fallback remains an error.
The tap accepts VPIO's own rate/layout, then the existing converter emits
24 kHz mono Float into the existing 2400-sample pcm16 streaming buffer. Only
the processed arm's conversion allocation is bounded to its input frame
clock, avoiding extra converter padding. Legacy conversion stays unchanged.

## Offline evidence

Archie production RED before forwarding the request, then unchanged fixture:

```
C1 RED echo commit=1 brain_calls=1
C1 GREEN echo commit=0 brain_calls=0
C1 CONTROL speech commit=1 brain_calls=1
```

Dictate C1VoiceProcessingTests, injected unit factory and real PCM conversion:

```
C1 GREEN wiring unit=vpio ducking=min format_out=24000Hz/1ch/pcm16 dictation_unit=halout bluetooth_unit=unchanged
C1 CONTROL refused voice_processing=unavailable reason=enable_refused fallback=halout capture_ok=1
C1 CONTROL refused voice_processing=unavailable reason=ducking_refused fallback=halout capture_ok=1
C1 CONTROL refused voice_processing=unavailable reason=start_refused fallback=halout capture_ok=1
Test run with 4 tests in 1 suite passed after 0.007 seconds.
```

Live echo rejection is unmeasured offline. The GREEN echo gate uses a fake
VPIO subtracting a known synthetic speech-like playback reference; it proves
request wiring and the real VAD/commit/brain gate, not Apple's acoustic AEC.
No devices, providers, audio IO, event taps, windows or dispatcher are used.

Archie compiles against the unchanged b74b068 pin using the existing
CaptureKind parameter. The manager must re-pin after merging these commits.

## Latency telemetry

AppController's existing timeline and the hosted conversation session-end
line share `CaptureStats.startupFields`. Refusal remains `unavailable` even
when the fallback itself throws. The latency tests use synthetic stats and
an injected unit factory only:

```
C1 LATENCY live=unmeasured logged_fields=engine_start_ms,first_buffer_ms,voice_processing
Test run with 2 tests in 1 suite passed after 0.002 seconds.
```

The first live session will expose these fields for comparison. The required
live before/after delta budget is at most +100 ms; that delta is unmeasured
without microphone access, and no offline wall-time result substitutes for it.
