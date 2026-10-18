# Native guard inventory — Dictate 1.17 (Archie v54 R4 / R4b)

Scope: the raw AVFoundation constructors and calls named by the GPT-6 review. Swift `do/catch` does not
catch an Objective-C exception; one that reaches a Swift frame with no Objective-C handler above it aborts
the process. This file lists, for each named call, either the enclosing guard (file:line), a forced-fault
test plus fix (Dictate only), or a scoped `NOT DONE (<reason>)`. It does NOT claim that every native call in
Dictate or Archie is protected. Line numbers are for the commit that adds this file.

## The guard

- `Sources/DictateObjC/DictateObjC.m:2` — `DictateTryObjC`: `@try { block() } @catch (NSException *)` → `NSError`
  (`userInfo["name"]`, `["reason"]`).
- `Sources/DictateCore/MicStartChain.swift:6` — `captureObjC { … }` runs a Swift closure inside `DictateTryObjC`.
- `Sources/DictateAppKit/HeadsetNativeBoundary.swift:39` — `HeadsetNativeBoundary.call(stage) { … }` runs each headset
  conversion stage inside `captureObjC` (line 41) and turns a caught exception into `HeadsetNativeFailure(stage:)`.
  It is called inside the caller's lock closure or ring-slot closure, so the exception is caught before anything
  unwinds through Swift frames, and the lock or slot is released as usual.
- `Sources/DictateAppKit/NativePCM.swift` — `dictate_pcm_format` / `dictate_pcm_buffer` (`DictateObjC.m`), each with its own
  `@try`. Used inside the boundary for the fixed 24 kHz mono target format and the output buffers.

Evidence: `Tests/DictateAppKitTests/R4NativeHeadsetTests.swift`. Every stage × backend × phase below is forced with
`[NSException raise:@"DictateForcedHeadset"]` from a seam inside the guarded closure, in a bounded child process
with offline PCM. On v1.16 every forced row aborted the child (`NATIVE RED … child_signal=SIGABRT`). With 1.17 the same
recorder converts its next buffer (`NATIVE GREEN … caught=DictateForcedHeadset alive=1 second_buffers=1 … second_nonzero=1`).
Controls: `CONTROL native_guard_positive` (captureObjC and NativePCM.convert catch a real raised NSException),
`CONTROL native_guard_negative` (no fault → nothing caught, real frames), and four `NATIVE NEGATIVE` rows
(unforced, same harness).

## Dictate headset conversion — fixed in 1.17 (forced-fault test + fix)

| Review ref (v1.16) | Stage | 1.17 call site → guard |
|---|---|---|
| `AudioRecorder.swift:130` stored target format | `target_format` | `AudioRecorder.swift:1461` (built with each converter via NativePCM) → boundary |
| `AudioRecorder.swift:1004` tap-install converter | `target_format`, `converter` | `AudioRecorder.swift:1004` → `makeHeadsetConverter` (`:1460`) → boundary; also inside the existing `captureObjC` of `installTapAndStart` |
| `AudioRecorder.swift:1412` converter on first buffer / format change | `target_format`, `converter` | `AudioRecorder.swift:1420` (inside the recorder lock's closure) → `:1461`/`:1464` → boundary |
| `AudioRecorder.swift:1418` output buffer | `output_buffer` | `AudioRecorder.swift:1431` → boundary + NativePCM |
| `AudioRecorder.swift:1421` `converter.convert` | `convert` | `AudioRecorder.swift:1436` → boundary; a converter that raised is dropped and the next buffer builds a fresh one |
| `HeadsetCaptureUnit.swift:19` converter factory (`makeConverter`) | `converter` | invoked only at `HeadsetCaptureUnit.swift:276` → boundary |
| `HeadsetCaptureUnit.swift:35` stored target format | `target_format` | `HeadsetCaptureUnit.swift:270` (NativePCM) → boundary |
| `HeadsetCaptureUnit.swift:144` start: mono format | `input_format` | `HeadsetCaptureUnit.swift:273`, reached from start `:156` → boundary |
| `HeadsetCaptureUnit.swift:149` start: converter | `converter` | `:276` from start `:156` → boundary |
| `HeadsetCaptureUnit.swift:409` format change: mono format (+ converter at :429) | `input_format`, `converter` | `:273`/`:276` from `handleFormatChange` `:520` → boundary |
| `HeadsetCaptureUnit.swift:302` input buffer (ring-slot closure) | `input_buffer` | `HeadsetCaptureUnit.swift:375`, inside the `context.nextSlot` closure (`:373`) → boundary; the slot is still released and counted |
| `HeadsetCaptureUnit.swift:319` output buffer | `output_buffer` | `HeadsetCaptureUnit.swift:402` → boundary + NativePCM |
| `HeadsetCaptureUnit.swift:323` `converter.convert` | `convert` | `HeadsetCaptureUnit.swift:415` → boundary; the converter is dropped and rebuilt for the following slots (`:430`) |

Recovery: a caught fault logs `headset_native_error backend=<engine|auhal> stage=<stage> exception=<name>` once per
stage, and `headset_native_recovered=1 backend=…` when a buffer converts again. These are stage and exception names
only, never audio or text. The unit or recorder stays running. AUHAL: a fault during start leaves the chain pending
(`pendingRebuild`), and the worker rebuilds it before the next buffer. A fault during a format change marks the chain
mismatched and retries the change at the top of the next drain (`pendingFormatChange`). Calls whose input is the
hardware format (the input format, the converter, the AUHAL input buffer, `convert`) keep their v1.16 constructors
inside the guard, so they accept every format v1.16 did and keep its `NSError` path. NativePCM's 32-channel and
384 kHz checks are used only for the fixed 24 kHz mono target.

## Remaining raw constructors from the review

### Dictate

- `Sources/DictateAppKit/RigSpeaker.swift:55`/`:57` (v1.16) `AVAudioEngine()` / `AVAudioPlayerNode()`: **fixed (forced-constructor test + fix).**
  Both are now built by `RigSpeaker.makePlayback` (`RigSpeaker.swift:81`) inside `captureObjC` (`:83`). A constructor
  exception returns `result=engine_error` instead of aborting. Test: `R4NativeHeadsetTests.rigConstructorFault`, a child
  whose injected constructor raises `DictateForcedHeadset` (no engine is constructed), passes as
  `CONTROL rig_constructor_guard PASS result=engine_error`. The engine's later operations were already guarded by
  `dictate_rig_start` / `dictate_rig_schedule_play` / `dictate_rig_stop` (`DictateObjC.m`).

### Archie (read-only for this lane: inventory only)

All paths are in the Archie repo, checked at `archie-v54` 8bca2a8.

- `Sources/ArchieVoiceMac/AVAudioEngineAdapter.swift:1338` `AVAudioPlayerNode()` in `makePlayerNode()`.
  `NOT DONE (Archie repo is read-only for Dictate R4. The constructor has no enclosing @try: its callers playerNodeReady/soundPlayerNodeReady, :431/:1143/:1271, run on plain Swift frames. Only the following attach/connect go through archie_audio_action. Needs an Archie lane with a forced-constructor test.)`
- `Sources/ArchieVoiceMac/AVAudioEngineAdapter.swift:1560` `AVAudioEngine()` in `makeEngine(offline:)`.
  `NOT DONE (Archie repo is read-only for Dictate R4. Called from init :183 and the engine rebuild :954 with no enclosing @try. Only archie_manual_mode, the offline path, is guarded.)`
- `Sources/ArchieVoiceMac/AppleSpokenVoice.swift:103` `AVSpeechSynthesizer()` and `:106` `AVSpeechUtterance(string:)` (also `:107` `AVSpeechSynthesisVoice(identifier:)`).
  `NOT DONE (Archie repo is read-only for Dictate R4. They are built on the main actor outside any @try. Only the write, archie_speech_write :109, is guarded.)`
- `Sources/ArchieMac/Voice/SpeechSynthesizing.swift:36` `AVSpeechSynthesizer()` and `:37` `AVSpeechUtterance(string:)`.
  `NOT DONE (Archie repo is read-only for Dictate R4. Built outside any @try. Only archie_speech_write, the next call, is guarded.)`

## Observed, not changed

- AUHAL drain (v1.16 behaviour, kept): a drain that applies a format change still labels that drain's pending slots
  with the hardware format it read before the change. Those slots fail conversion (`headset_convert_error=`) and are
  dropped. This touches real-mic behaviour, so 1.17 leaves it alone. Only the native-fault retry runs before the
  drain reads the format.
- This inventory covers the calls the review named. Other AVFoundation calls in Dictate (the engine tap path
  in `AudioRecorder` under `captureObjC`, `BuiltinCaptureUnit` and `AppleTranscriber` through NativePCM) were not
  re-audited in this lane.
