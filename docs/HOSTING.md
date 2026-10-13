# Embedding DictateKit

Link the `DictateKit` library product and import both modules. Keep the host alive
on the main actor. Construction installs no hotkeys, starts no capture, and
creates no menu. Enable hotkeys when the host is ready for macOS permissions.

```swift
import DictateCore
import DictateAppKit

@MainActor final class ExampleHost {
    let engine: DictationEngine
    let hotkeys: OptionDoubleTapMonitor
    init() {
        engine = DictationEngine(keyStore: KeyStore(), paths: AppPaths(), surface: .none)
        hotkeys = OptionDoubleTapMonitor()
        engine.onState = { print($0) }
        engine.onTranscript = { text, timeline in print(text, timeline) }
        hotkeys.onDoubleTap = { [weak self] in self?.engine.start() }
        hotkeys.onTap = { [weak self] in self?.engine.tap() }
        hotkeys.onEscape = { [weak self] in self?.engine.escape() }
    }
    func enableHotkeys() -> Bool { hotkeys.start() }
    func stop() { hotkeys.stop(); engine.cancel() }
}
```

`start()` begins a dictation; `finish()` finishes a recording (or pastes held text).
`tap()` is the single-⌥ handler: while idle it pre-starts the microphone so it is live
by the second tap (no lost first words); otherwise it behaves like `finish()`.
`cancel()` and `escape()` cancel capture/transcription or dismiss an outcome.
`pasteHeld()` recovers held text once; `copyHeld()` copies its current preview.
The host can drive these methods itself without creating a hotkey monitor.
Call `engine.recoverStaleMute()` once at host launch: if a previous host run quit or
crashed while output was muted, it restores the mute flag and returns the event
(`mute_recovered=1` or `restore_failed`); nil when nothing was pending.

Set `engine.mode = .captureOnly` for chunked STT with the raw joined transcript
in `onTranscript`, without cleanup or clipboard changes. Completion returns to
`.idle`; `.pasted` is emitted only for insertion. Set `engine.forceFallback = .quota`
to use Apple on-device STT and local Ollama cleanup. Mode and fallback are sampled
at recording start. Quota sessions add `fallback=quota` to the timeline and log.

`KeyStore()` reads the Groq key through `/usr/bin/security` (the keychain ACL names that
tool, so a rebuilt or re-signed host never raises a keychain dialog). The in-process
SecItem path is opt-in (`KeyStore(reader: { try KeychainAPIKey.read(service: $0) })`) and
runs with user interaction disabled. A key that cannot be read logs
`keys=groq:denied key_unavailable=prompt_suppressed` (if a dialog would have been needed)
and the session falls back to Apple STT + local cleanup (`fallback=no_key`).

`onDiagnostic` receives every diagnostic line the standalone app writes to
`dictate.stderr.log` (`timeline:` with `mic=`, `fmt=`, `bridge_src`, `first_buffer_ms`,
`peak_dbfs`; `keys=`; `media=`), on any thread, counts only. In a host those lines
otherwise go to the host's own stderr; tee them into the host's log.

A host that mutes media for its own capture can reuse the same mute logic:
`OutputMuter(device: SystemOutputMute(), stateFile: <its own muted.state>)` — mute FLAG
only (never volume), verified restore, 5 s settle re-check across Bluetooth profile
flips, crash record kept until verified; call `recoverIfNeeded()` at launch. Dictate
mutes on the first live buffer (after any headset profile flip) and restores on
every end path.

`onGroqRateLimit` runs on the main actor for each Groq response, including errors,
hedges, warmup, and incremental/final/racing cleanup. Missing or invalid header
counts are nil. `.none` suppresses every panel operation while preserving outcome
timers, cancellation, diagnostics and recovery. Default `.pill`/`.dictate` retain
the standalone behavior. Audio and transcript text remain in memory only; paths
select the existing count-only log, mute-recovery file, and vocabulary location.
The example prints text only to demonstrate delivery; the engine never stores it.

Groq quota: every Groq response (STT and cleanup, including errors, hedges and warm-up)
is recorded as counts and dates only in `~/Library/Application Support/Dictate/groq-quota.json`
(atomic writes; pass `DictationEngine(..., quotaFileURL:)` to relocate it, and `quotaFileURL`
reads it back). `engine.groqQuota` (or `GroqQuota.current` for the default file) has the
per-endpoint limits, remaining counts and reset time. At recording start, an endpoint with
under 10 % of its requests left (until its reset, or 15 min without one) falls back
automatically: STT to Apple on-device, cleanup to local Ollama. The session logs
`fallback=quota quota_low=stt|cleanup|both`; `forceFallback = .quota` still means both.

On macOS, microphone access is needed for capture, Apple Speech assets must already
be installed for quota fallback, and Accessibility/Input Monitoring is needed for
hotkeys and insertion. Engine construction performs no asset download. The existing
standalone launch continues to prepare assets as before.

`injectedAudioURL:` (or env `DICTATE_INJECT_WAV=<path>`) replaces the microphone with a 24 kHz mono 16-bit WAV, paced in real time, then silence until finish(); STT, cleanup and paste stay real — for unattended end-to-end checks.

## Capture contract for hosts (v1.11, frozen)

A host that runs its own capture session (Archie's ⌘⌘ conversation) uses `AudioRecorder` directly. These members are frozen by `Tests/DictateAppKitTests/HostContractTests.swift` (a non-`@testable` import): changing a name or type breaks that file before it breaks a host.

- `public init()`: no audio until `startAsync`.
- `onPCMChunk: (([Int16]) -> Void)?`: 24 kHz mono pcm16, 100 ms chunks (`AudioRecorder.chunkSamples` = 2 400), in order, outside the recorder's lock.
- `onCaptureFailure: ((CaptureFailure) -> Void)?`, `resetCapture()`, `startAsync(device: MicChoice) async throws`, `stop() -> [Float]`.
- `stats: AudioRecorder.CaptureStats`: `bridgeSource`, `bridgeMs`, `ioOps`, `ioHeld`, `speechSections`, `recordingMs` (plus, v1.11, `carrier`, `headsetCarriedMs`, `captureIntervalsTruncated`, `kind`).
- `kind: CaptureKind` (`.dictation` default, `.conversation`): a label set before `startAsync`. Capture is identical; `stats.sessionEndFields` begins `kind=…`, so a host writing `session=<id> event=end outcome=… ` + `stats.sessionEndFields` logs the same line Dictate does.

The muter and the arbitration between a host's own features live in the host.

### v1.12 additions (the contract above is unchanged)

- **One capture owner per process.** `startAsync` acquires the process-wide `CaptureLeaseBroker` lease (kind = `kind`). It throws `CaptureLeaseBroker.Refusal.busy(holder:)` when another capture (any `AudioRecorder` in the process, e.g. the host's dictation while a conversation runs) is live — map it to your own refusal (`prestart_skipped=…`) — and `.releasePending(holder:)` when the previous owner's hardware release did not complete within 2.0 s. While a release is pending it waits; the first waiter is admitted once the hardware acknowledged.
- `stop()` still returns at once. `await recorder.awaitRelease()` (`CaptureLease.State?`: `.released`, or `.quarantined` when the teardown never completed) is the boundary after which another feature may treat the microphone as free. Do not treat `stop()` returning as that boundary.
- `currentLease: CaptureLease?`: `claimMute()` (only the active lease may own the media mute; relinquished at release), `grantNote`, `note`.
- `init(headsetBackend: HeadsetBackend)` (`.engine` default, `.auhal` = the explicit-device AUHAL headset client; otherwise `DICTATE_HEADSET_BACKEND`). Experimental until the live A/B (`tools/live-ab-protocol.md`).
- `stats` adds `carrierFrames`, `lease`, `instrumentation`; `stats.sessionEndFields` appends them after `io_held=…`, and `ioOps`/`ioHeld` carry the v1.12 split (`attempted/completed/failed/framework`, `io_obligations=`).

