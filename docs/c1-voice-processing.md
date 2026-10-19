# Conversation capture voice processing (C1)

Status: native wiring, offline AEC-model gate, latency telemetry, converter
continuity, Bluetooth-output control and regression controls passed. Live echo
rejection and live latency are unmeasured offline. Whether Apple's AEC reference
includes audio rendered by Archie's separate playback engine is undocumented
(see "Echo reference coverage"). The Archie companion report documents the
playback/capture timeline and unchanged RED/GREEN fixture.

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
24 kHz mono Float into the existing 2400-sample pcm16 streaming buffer
(`AudioRecorder` re-chunks to `chunkSamples`). The converter and its per-callback
allocation (budget + 32 frames) are byte-identical to b74b068 on every arm; an
earlier processed-arm-only allocation bound was removed (see "Converter continuity").

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

## Converter continuity

Codex's first continuity check compared LIVE converter output counts
(`whole.count 22520 == 24000`, `streamed 23640 == whole 22520`). Those counts
differ because AVAudioConverter's sample-rate converter holds back its trailing
look-ahead until end-of-stream (priming), and how much it holds depends on the
call pattern. Frames are held, not lost: `AudioRecorder.offlineFlushConverter()`
(tests only) drains the same production converter with end-of-stream.

Same probe on the untouched b74b068 converter (disposable `git archive` copy,
seam added there only, copy deleted):

```
C1 PREEXISTING b74b068 rate=48000 whole=22520 streamed=23928 whole_flushed=24000 streamed_flushed=24000 max_err=0.0
C1 PREEXISTING b74b068 rate=44100 whole=22282 streamed=23905 whole_flushed=24000 streamed_flushed=24000 max_err=0.0
```

Codex's processed-arm allocation bound (`ceil(budget)` instead of `budget + 32`)
was added only to satisfy its own wiring assertion (per-callback chunk <= 2400,
which b74b068's converter path never promised: it emits 2432 and re-chunks
downstream). It lost no samples, but it raised the frames the converter holds in
steady state from 72 to 360 at 48 kHz (3 ms -> 15 ms). It is removed; the
wiring test now asserts b74b068's allocation and the flushed frame total.

Corrected test: end-of-stream-flushed, sample-aligned comparison, threshold
unchanged (1e-5), plus alignment to the ideal 24 kHz signal (1e-4) and positive
controls that drop / repeat one sample at a callback boundary:

```
C1 CONTINUITY rate=48000 whole=24000 streamed=24000 max_err=0.0 cause=priming
C1 CONTINUITY rate=44100 whole=24000 streamed=24000 max_err=0.0 cause=priming
C1 CONTINUITY detail rate=48000 whole_live=22520 whole_held=1480 streamed_live=23928 streamed_held=72 align_err=1.9967556e-06
C1 CONTINUITY detail rate=44100 whole_live=22282 whole_held=1718 streamed_live=23905 streamed_held=95 align_err=2.7865171e-06
C1 CONTINUITY CONTROL dropSample detected=1 count=24000 max_err=0.007529541 align_err=0.0073125567
C1 CONTINUITY CONTROL repeatSample detected=1 count=24001 max_err=inf align_err=0.0073162084
```

## Echo reference coverage

Archie renders TTS through its own AVAudioEngine (`AVAudioEngineAdapter`);
capture is DictateKit's engine. The SDK headers (Command Line Tools SDK) say:

- `AVAudioIONode.h:142-143`: "If enabled, the input node does signal processing
  on the incoming audio (taking out any of the audio that is played from the
  device at a given time from the incoming audio)."
- `AVAudioIONode.h:146-147`: "Voice processing requires both input and output
  nodes to be in the voice processing mode. Enabling this mode on either of the
  IO nodes automatically enables it on the other IO node."
- `AUComponent.h:269-273` (kAudioUnitSubType_VoiceProcessingIO): "Bus 0 is used
  for the output side, bus 1 is used to get audio input ... taking out any of
  the audio that is played from the device at a given time from the incoming audio."
- `AudioUnitProperties.h:2684,2719`: VPIO ducks "other (i.e. non-voice) audio",
  so it is aware of audio outside its own bus 0, but only ducking is specified.

"Played from the device" reads as the output device's whole mix, while the
pairing rule ties the processing to the unit's own output node. No header says
whether audio rendered by ANOTHER engine / IO unit on the same output device is
in the cancellation reference.

```
C1 REFERENCE other_engine=undocumented source=AVAudioIONode.h:142-147
```

Decision (per lane rule): undocumented, so voice processing stays enabled only
because the Bluetooth control and every regression control pass. Uncertainty
recorded literally: if Apple's reference covers only the capture engine's own
output node, conversation VPIO cancels nothing of Archie's TTS and costs AGC,
format change and a full-duplex output IO on the built-in route. The offline
GREEN echo fixture models a reference that includes Archie's playback; the first
live built-in-speaker session must confirm it. Ducking of other audio is at
minimum, which also applies to Archie's own playback engine.

## Bluetooth output edge

Raza's headset often falls back to the BUILT-IN mic while OUTPUT stays on the
Bluetooth headset (`headset_digital_silence`). VPIO opens the output side too
(AVAudioIONode.h:147) and was the prime suspect for the WH-1000XM6 silent-output
report, so `startCaptureInput` enables it only when the input is built-in AND
the default output transport reads non-Bluetooth (Bluetooth / Bluetooth LE ->
`bluetooth_route`; unreadable -> `route_unknown`). This mirrors Archie's
`AVAudioEngineAdapter.shouldUseVoiceProcessing` (false when EITHER side is
Bluetooth). The mid-session built-in fallback bridge (`BuiltinCaptureUnit`) is
AUHAL and never VPIO. RED (production mutated to ignore the output transport,
then restored): `made [.vpio] == [.halout]` failed, `voice_processing=on`.
GREEN:

```
C1 CONTROL bt_output_builtin_input voice_processing=unavailable reason=bluetooth_route
```

## Session-end field order

`startupFields` is appended at the END of `sessionEndFields`, keeping the frozen
host-contract adjacency `carrier=… headset_carried_ms=… io_ops=…`
(HostContractTests failed with Codex's mid-line placement).

## Regression controls

```
C1*/CaptureLeaseRecorderTests/HostContractTests/R4NativeHeadsetTests/V53NativeAudioTests/HeadsetCaptureUnitTests/MicDeadTests/PauseBridgeTests/WAVInjectedRecorderTests:
Test run with 62 tests in 12 suites passed after 17.215 seconds with 1 known issue.
V55LongPasteTests|V15PasteConfirmationTests|V53PasteReviewTests|PasteboardRestoreTests:
Test run with 21 tests in 4 suites passed after 0.145 seconds.
```

The known issue is MicDeadTests' pre-existing `withKnownIssue` real-clock RED.
