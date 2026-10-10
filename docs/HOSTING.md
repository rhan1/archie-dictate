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
        hotkeys.onTap = { [weak self] in self?.engine.finish() }
        hotkeys.onEscape = { [weak self] in self?.engine.escape() }
    }
    func enableHotkeys() -> Bool { hotkeys.start() }
    func stop() { hotkeys.stop(); engine.cancel() }
}
```

`start()` begins a dictation; `finish()` finishes a recording (or pastes held text).
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
