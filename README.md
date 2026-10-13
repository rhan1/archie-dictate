# Archie Dictate

Dictate is a menu-bar dictation application for macOS. Press **⌥⌥** (double-tap Option) to start recording, speak naturally in any application, and tap **⌥ once** (or click the checkmark) to finish—Dictate transcribes your speech via Groq, cleans up filler words and spoken self-corrections, and pastes the result directly at your cursor. Audio output is automatically muted while you talk (using the macOS mute flag, leaving system volume unchanged) and restored when you finish. If network or cloud services are unavailable, Dictate automatically falls back to Apple on-device speech recognition and local Ollama cleanup.

## Quick start

1. Install the Xcode command line tools (`xcode-select --install`) and [Homebrew](https://brew.sh).
2. `git clone https://github.com/rhan1/archie-dictate.git && cd archie-dictate` — all `tools/` commands run from the repo root.
3. Get a Groq API key at [console.groq.com](https://console.groq.com).
4. Store the key in your login keychain: `security add-generic-password -s groq-api -a "$USER" -w '<your-groq-key>'`
5. Install Ollama and start the fallback cleanup model (optional — offline cleanup fallback): `brew install ollama && brew services start ollama && ollama pull llama3.2:3b-instruct-q4_K_M`
6. Install the Swift 6.3.3 toolchain from [swift.org](https://www.swift.org/install/) and run the installer with **Install for me only**, so it lands in `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain`.
7. Create the signing identity: `tools/ensure-signing-identity.sh`
8. Build the application bundle: `tools/make-app.sh`
9. Install and launch the agent: `tools/install-launchagent.sh`
10. Grant **Microphone** and **Accessibility** permissions to `Dictate.app` in **System Settings → Privacy & Security**.
11. When the keychain dialog appears (right after the app first launches during install), click **Always Allow**.
12. Press **⌥⌥** anywhere to try it.

## Requirements

- **Operating System & Architecture:** macOS 26 on an Apple Silicon Mac.
- **Xcode Command Line Tools:** Required for the SDK and linker (`xcode-select --install`).
- **Swift 6.3.3 Toolchain:** Download the macOS package installer from [swift.org](https://www.swift.org/install/) and run it with **Install for me only** so it lands in `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain`. That path is what the build and bench scripts (`tools/*.sh`) use; a system-wide install goes to `/Library/Developer/Toolchains` and the scripts will not find it.
- **Homebrew:** Required for installing dependencies ([brew.sh](https://brew.sh)).
- **Ollama (Optional):** Only needed for the offline cleanup fallback (`llama3.2:3b-instruct-q4_K_M`). If omitted, cloud cleanup operates normally, and Dictate pastes raw transcripts when offline.

## Signing identity

Dictate relies on a persistent code-signing identity to preserve macOS permissions across rebuilds.

- **What `tools/ensure-signing-identity.sh` does:** Creates a self-signed `"Dictate Dev"` code-signing identity in your login keychain. macOS presents a single GUI trust/password prompt; enter your login password to trust the certificate for code signing.
- **Why it matters:** macOS ties Transparency, Consent, and Control (TCC) permissions—such as Accessibility, Microphone, and keychain access—to the binary's code signature. Without a persistent identity, `tools/make-app.sh` falls back to ad-hoc signing, requiring you to re-grant permissions in System Settings after every rebuild.
- **How to check:** Verify the identity in your login keychain:
  ```bash
  security find-identity -v -p codesigning
  ```
  Look for `"Dictate Dev"` with a valid hash in the output.

## Build overrides (`build.env`)

Every script in `tools/*.sh` sources `~/Library/Application Support/Dictate/build.env` if the file exists. You can use this file to configure custom settings without modifying repository files:

- `DICTATE_SIGNING_IDENTITY`: Code-signing identity name (defaults to `Dictate Dev`).
- `DICTATE_BUNDLE_ID`: Application bundle identifier (defaults to `dev.dictate.app`).
- `DICTATE_LABEL`: LaunchAgent service label (defaults to the bundle ID, `dev.dictate.app`).

Create the directory first, then the file:
```bash
mkdir -p "$HOME/Library/Application Support/Dictate"
cat > "$HOME/Library/Application Support/Dictate/build.env" <<'ENVEOF'
DICTATE_SIGNING_IDENTITY="Dictate Dev"
DICTATE_BUNDLE_ID="dev.dictate.app"
DICTATE_LABEL="dev.dictate.app"
ENVEOF
```

## Permissions

Configure the following permissions in macOS:

1. **Microphone & Accessibility:** Grant permissions to `Dictate.app` under **System Settings → Privacy & Security → Microphone** and **System Settings → Privacy & Security → Accessibility**.
2. **Input Monitoring:** If the hotkey does nothing even with Accessibility granted, also grant `Dictate.app` access under **System Settings → Privacy & Security → Input Monitoring** (macOS occasionally requires this for listen-only event taps).
3. **Keychain Access:** The "Dictate wants to use groq-api" keychain dialog appears right after the app first launches (during install), not on the first dictation; answer **Always Allow**.

## Usage

Use the **left Option** key (press and release cleanly without other modifier keys):

- **Start Recording:** Press **⌥⌥** (double-tap Option). Grey bars appear while the microphone warms up, followed by white bars when listening to your voice.
- **Finish Recording:** Tap **⌥ once** or click **✓**. Dictate transcribes the audio, runs cleanup, and pastes the text directly at your cursor.
- **Cancel:** Press **Esc** or click **✕** to cancel recording or dismiss a pill.
- **Held & Status Outcomes:** If a paste cannot land immediately (such as when switching apps during processing or when a service fails), the pill remains on screen for up to **20 seconds** displaying a status word (e.g., `held`, `no mic signal`, `no key`, `timeout`, `offline`, `error`).
  - Clicking **✓** or tapping **⌥ once** pastes the text into your active application.
  - The menu-bar microphone icon's **"Paste last dictation"** menu item retains the text for up to **10 minutes** in memory (RAM only, never saved to disk).
- **Audio Output Muting:** Output audio is automatically muted while you talk (toggling the hardware mute flag only, never altering the volume slider) and restored immediately afterwards, including after a crash upon next launch.

## Engine

- **Default (`groq-chunked`):** Audio is uploaded in short chunks while you talk, minimizing latency when dictation ends.
- **Automatic Fallback:** Apple on-device speech recognition (`Speech.framework`) serves as the automatic fallback if Groq chunk uploads fail.
- **Groq quota awareness:** The `x-ratelimit-*` counts from every Groq response are kept in `groq-quota.json` (counts only). When fewer than 10 % of an endpoint's daily requests remain, new dictations switch on their own: speech-to-text to Apple on-device, cleanup to local Ollama. The log shows `fallback=quota quota_low=stt|cleanup|both`. The switch ends when Groq's reset time passes.
- **Warm connection:** While Dictate is idle (up to 2 h after the last dictation) it sends an unmetered `GET /models` every 4 min so the first chunk of the next dictation skips the TLS handshake. Set `DICTATE_KEEPWARM=0` to disable.
- **Chunk-boundary repair:** When a chunk boundary splits a phrase like "uh, the screenshots" and Whisper hears "other screenshots", the two chunks are re-transcribed together once (at most 2 extra requests per dictation). Set `DICTATE_REJOIN_GUARD=0` to disable.
- **Fast start:** The first ⌥ tap starts the microphone; the recording keeps audio from 150 ms before the second tap, so the first words are not lost.
- **Force Apple-Only STT:** To force Apple on-device recognition for the LaunchAgent, set `DICTATE_STT=apple`:
  ```bash
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" ~/Library/LaunchAgents/<label>.plist 2>/dev/null
  /usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:DICTATE_STT" ~/Library/LaunchAgents/<label>.plist 2>/dev/null
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DICTATE_STT string apple" ~/Library/LaunchAgents/<label>.plist
  launchctl bootout "gui/$UID/<label>" 2>/dev/null; sleep 2; launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/<label>.plist
  ```
  *Note:* launchd only re-reads the plist on bootstrap (a plain restart reuses the cached job). Re-running `tools/install-launchagent.sh` regenerates the plist and drops this override, so repeat these lines after it. `<label>` is `DICTATE_LABEL` (default `dev.dictate.app`).

## Bluetooth headsets

A microphone open on a Bluetooth headset switches macOS to the hands-free profile (HFP, 16 kHz). Dictate releases the audio engine within 2 s after every dictation, so output audio returns to high-fidelity A2DP (`bt_after3s=a2dp … engine_allocated=false`). While the headset voice link establishes (about 1–2 s), Dictate records concurrently from the Mac built-in microphone so initial speech is not lost. A `bt_hfp_foreign=1` note means another app is holding the headset microphone while Dictate is idle; `tools/probes/bt-probe.swift` prints the headset's live sample rate.

v1.9's Bluetooth behaviour is unproven on a headset until the live protocol in [tools/live-protocol.md](tools/live-protocol.md) passes.

### One capture lease (v1.12)

Every capture — a dictation (⌥⌥) or a host's conversation (⌘⌘), from any `AudioRecorder` in the process — holds the process-wide `CaptureLeaseBroker` lease. The lease owns the headset client, built-in continuity, the frame timeline, the recovery episode, mute ownership (`claimMute()`: only the active lease) and **release completion**:
- `stop()` still returns the captured samples at once, but the lease stays *releasing* until every hardware part it started has acknowledged teardown — the built-in unit on its own serial queue, the headset client on the recorder's executor. `await recorder.awaitRelease()` returns `.released` (or `.quarantined`); the log line is `lease_released=N state=released lease=N lease_kind=… lease_wait_ms=N release_ms=N`.
- A new start while another lease is **active** is refused (`CaptureLeaseBroker.Refusal.busy(holder:)`, note `lease_refused=busy holder=…`; a host maps it to its own `prestart_skipped=…`). While the previous lease is **releasing**, `startAsync` waits up to 2.0 s: the first waiter is admitted when the hardware acknowledges, later ones are refused — one owner per completed release (`lease_admitted=1 … lease_wait_ms=N`).
- A release still pending after 4.0 s (a wedged CoreAudio call) is **quarantined**: it is never reused, its late callbacks stay rejected, and the next lease is admitted with `quarantined_prev=1` rather than blocking capture until relaunch.
- Every frame callback carries the epoch of the start that produced it; a reused unit's late callback from an earlier session never enters a newer one.
- The lease kind is `AudioRecorder.kind` (`.dictation` | `.conversation`); the session end line carries `lease=N lease_kind=… lease_wait_ms=N`.

### Headset backend (v1.12, `headset_backend=engine|auhal`)

`DICTATE_HEADSET_BACKEND=auhal|engine` (default `engine`, unchanged), or `AudioRecorder(headsetBackend:)` for a host, picks the client that captures a **Bluetooth default input**: `engine` is the AVAudioEngine input node (it follows the default device and its aggregate); `auhal` is `HeadsetCaptureUnit`, an explicit-device, input-only AUHAL bound to the headset's UID (output element disabled, no aggregate, hardware rate taken as-is and converted to 24 kHz off the IO thread; rate changes, invalid rates, converter failure, device loss and callback cessation are ordinary state transitions: `headset_format_changed=`, `headset_format_invalid=`, `headset_convert_error=auhal`, `headset_device_lost=1`, `headset_callbacks_stopped=1`). Built-in, other inputs and an explicit device choice always use the engine. Both arms are instrumented identically on the session end line: `headset_backend=… route_uid=… fmt_epochs=gen:rateHz/ch@ms,… io_callbacks=builtin:N,headset:N frames=… zeros=… rms_dbfs=… takeover_ms=… fallback_ms=…`. The `auhal` arm is an **experiment**: which backend ships is decided by the live A/B in [tools/live-ab-protocol.md](tools/live-ab-protocol.md); never run both clients at once.

### Dual-source capture and health clock

- **Owned built-in capture:** The built-in microphone runs as an owned raw AUHAL unit pinned directly to the physical device (`builtin_backend=auhal`), isolated from AVAudioEngine's default aggregate tracking. Its device binding is read back every 100 ms (`bridge_device_check=ok|drift`); if it ever reports another device, the built-in is treated as dead rather than trusted.
- **100 ms health clock:** An independent evaluator monitors both inputs every 100 ms. A source is marked stale after 600 ms without fresh frames (with startup grace periods of 1.0 s for the built-in mic and 2.0 s for the headset) and transport-silent after 1.5 s of exact digital zeros (distinct from quiet speech).
- **Dynamic switching:** Dictate switches to the alternate input only when that source is fresh (frames delivered within 300 ms) and has at least 150 ms of real signal (`headset_signal_start=1`), in either direction (fallback no longer latches).
- **Fast failure:** If no carrying source has valid signal, Dictate issues an immediate warning (`health=warn reason=…`) and terminates the dictation 2.0 s after the last useful audio with outcome `error:mic_dead` and pill status word `no mic signal`, logging actual audio duration and byte counts (`fail reason=mic_dead …`).
- **Ordered delivery:** Audio chunks are queued and delivered in sequence outside the recorder lock so transitions never reorder audio.

### Unified Bluetooth recovery

All headset restart paths (startup retries, first-buffer timeouts, format configuration changes, and digital silence recovery) are governed by a single session-level episode:
- At most one restart per 1.5 s window after input format has stabilized for 200 ms.
- v1.9: when the configuration change finds the headset engine already stopped (AVAudioEngine auto-stops it on the A2DP→HFP switch), the first re-attach is immediate (`bt_recovery=immediate path=configuration engine_running=0 after_ms=…`): macOS tears an idle voice link down about 250 ms after it connects unless a client is doing IO. Later attempts keep the debounce.
- Recovery succeeds only when audio frames with signal arrive within 1.0 s (not merely when `start()` returns). Outcome words: `result=frames` (signal), `result=silent_frames` (buffers, all digital zeros — an idle link; treated like no frames), `result=no_frames`.
- v1.9: a headset that recovers after the built-in took over carries again once it delivers 150 ms of signal (`bridge_switch=headset reason=recovered`).
- Settle time after stopping is 300 ms.
- External contention (when another app holds the headset) is noted via `bt_external_busy=1`, keeping capture on the healthy built-in mic without spinning (at most 3 attempts per dictation). Non-Bluetooth inputs recover immediately.

### Diagnostic notes

The unified log and `~/Library/Logs/Dictate/dictate.stderr.log` record key timeline events:
- `session=<id> event=start|end`: Correlates session lifecycle with `kind=dictation|conversation` (v1.11), `recording_ms=`, `capture_intervals=` (`capture_intervals_truncated=1` when the 400-interval cap was hit: the list is then not coverage), `speech_sections=`, `builtin_frames_after_fallback=`, `builtin_backend=`, `carrier=` and `headset_carried_ms=`.
- `carrier=builtin:0-1100,headset:1100-15110 headset_carried_ms=14010` (session end line, v1.11; v1.12 computes it from the per-frame source timeline — each change at the sample time of the first frame the new source contributed): which source fed the dictation, as ms from the second tap — `builtin` (the bridge's built-in unit), `headset` (the Bluetooth default input) or `default_input` (a non-Bluetooth default input, no bridge). `bridge_src=` names the bridge, not the carrier: on 10-13 R4 `bridge_ms=1106 bridge_src=builtin` was a headset takeover that then carried 14 s. `headset_restart=1 result=skipped` = a restart was requested but never ran (coalesced into another recovery or obsolete); `still_silent` now only follows a restart that actually ran.
- `carrier_frames=builtin:0-1100,headset:1100-15106` (v1.12): the exact per-frame runs per source, gaps shown (a source that stopped delivering ends its run; `carrier=` closes its last interval at the recording end). `carrier_frames_truncated=1` past 32 runs — the totals stay exact and no run is stretched over missing time.
- `builtin_backend=auhal`, `bridge_device_check=ok|drift|lost`: Status of the physical built-in capture unit.
- `fallback_check builtin_fresh_at_fallback=1|0`: Verifies built-in freshness when falling back from a silent headset.
- `headset_signal_start=1`: Confirms non-zero headset signal arrival.
- `bt_external_busy=1`, `bt_recovery=requested|queued|immediate|settled`: Bluetooth recovery episode decisions (`settled … result=frames|silent_frames|no_frames`).
- `bridge_switch=headset reason=recovered`: a recovered headset carries again after a fallback.
- `mute_reapplied=1 uid=… reason=default_changed|devices_changed|rate_changed`: the output mute flag was reset during the dictation (a headset profile flip) and set again; the timeline's `media=muted>restored(verified) mute_reapplied=<n>` counts them. `mute_unsupported_uid=…`: that output exposes no settable mute flag (volume is never touched).
- `speech_sections=` counts speech sections relative to the dictation's own contrast (v1.10: the 95th-percentile window must be ≥ 6 dB over the 10th-percentile floor; a speech window is ≥ max(6 dB, half that contrast) over the floor and above −60 dBFS; −40 dBFS always counts), so a distant built-in fallback still shows its speech and constant noise shows none.
- `io_ops=start:N stop:N rebuild:N retap:N attempted:N completed:N failed:N framework:N io_held=N config_notifications=N io_obligations=O/D io_obligation=none|open:<reason> reattaches=N` (session end line, v1.10; split in v1.12): every engine operation DictateKit attempted on the headset (per kind; `stop` includes the final teardown, whose outcome lands after the line; `align:N` only when one ran), how many returned (`completed`) or threw (`failed`), and the stops the OS made itself (`framework`: a stopped-engine notification or an observed stop) — an application counter cannot prove HAL did not stop IO. v1.12 replaces v1.10's blind 1.0 s hands-off window with recovery anchored to observed IO: a stopped headset client — reported by a configuration notification or seen stopped by the 100 ms health clock — opens an **obligation** (`io_obligations=` opened/discharged) that gets ONE re-attach as soon as none is in flight (also a second stopped notification, which v1.10 swallowed); a re-attach is in flight until fresh headset frames arrive (early) or 1.0 s passes; if it brought no IO the obligation escalates once to the episode's restart (`bt_recovery=escalate`) and stays visible (`io_obligation=open:engine_stopped|io_ceased`) until IO is observed. `bt_recovery=hands_off path=configuration engine_running=1` = a running engine was left alone; `bt_recovery=obligation … in_flight=1` = a re-attach was already in flight; `bt_recovery=reattach path=obligation` = the health clock's re-attach. The tap converts in place (`bt_reattach_converted=1`) only until the current format generation delivered sustained signal; a recovery attempt succeeds only on SUSTAINED signal (150 ms of consecutive non-silent frames, the bridge's takeover test), never one nonzero buffer.
- `stt_dropped_low_speech_sentence=N stt_dropped_low_speech_pos=none|opening|tail|chunk stt_dropped_artifact=N stt_dropped_silent_chunk=N` (timeline, v1.11): Whisper's invented sentences at a dictation's edges ("Thank you." / "Dictate." after the last word) are dropped on audio evidence only — a sentence of the first chunk's opening or the last chunk's tail is placed on the chunk's timeline by its letter count and dropped only when its span holds no speech section and no ≥ 150 ms speech run, under 25 % speech windows, with ≥ 1 s of non-speech beyond the first/last speech section; "speech" for a drop is anything ≥ 6 dB over the dictation's own floor (or ≥ −40 dBFS), so soft words keep their sentence, and uncertain text is kept. A known artefact ("Thank you.", "Thanks for watching.", "Dictate.", "Bye.") is only a label (`stt_dropped_artifact`), never a reason. A chunk with no such window at all is emptied before it is streamed (`stt_dropped_silent_chunk`). Counts only, never the text; `DICTATE_EDGE_GUARD=0` disables it. v1.10's novelty rule (a sentence sharing no content word with the vocabulary or the next chunk) deleted valid text ("Hey. Cancel the London booking." lost its instruction) and is off unless `DICTATE_LOW_SPEECH_GUARD=1` (`pos=chunk`); its comparator is now the adjacent chunk only.
- `fail reason=mic_dead kept_ms=… last_delivery_ms=… sources=…`: Failure details when no input signal arrives.

### Bluetooth proof (`tools/bt-proof.sh`)

`tools/bt-proof.sh` inspects dictation sessions and validates capture integrity:
- Inspect recent system logs: `tools/bt-proof.sh --log <minutes>`
- Inspect a specific time window: `tools/bt-proof.sh --log-window '<start>' '<end>'` (e.g. `'2026-10-12 21:33:05' '2026-10-12 21:33:50'`)
- Inspect saved log dumps or test fixtures: `tools/bt-proof.sh --from-file <file>`
- With no arguments it still runs the older two-minute interactive profile check (two short dictations).

A session achieves `BT-PROOF: PASS` only when all of the following hold:
1. **Outcome:** `outcome=ok`, or `held` with retained characters (`chars>0`).
2. **Coverage:** Sample-time capture coverage ≥95 % of the recording duration after a ≤1.0 s startup allowance, with no gap >600 ms (calculated from `capture_intervals=`).
3. **Speech evidence:** At least 3 speech sections (`speech_sections>=3`, runs of ≥300 ms of speech windows — see `speech_sections=` above — separated by ≥200 ms).
4. **Transport recovery:** Every dropped eSCO link (`Dropping eSCO creation`) must either be re-created within 1.5 s followed by headset audio frames (`headset_signal_start=1`) within 3.0 s of that creation (v1.11: a later signal no longer certifies the drop), or fall back onto a fresh built-in mic (`builtin_fresh_at_fallback=1`) within 2.0 s of the drop, in the same session, whose end line shows kept frames (`builtin_frames_after_fallback>0`).
5. **Honest coverage (v1.11):** a session with `capture_intervals_truncated=1` or ≥ 400 intervals fails (`truncated_intervals@<session>`); an event inside two sessions' windows fails both (`ambiguous_session@<t>`).

Missing sessions, duplicate session IDs, missing outcomes, or log errors fail (`BT-PROOF: FAIL <reason>`). Before the final line the gate prints its positive-control counters (`DROPS_SEEN= RECOVERED= FALLBACKS=`) and separate verdicts: `VERDICT continuity=`, `VERDICT headset=` (PASS only when the headset actually carried: `headset_carried_ms>0` or a bounded recovery), `VERDICT content=`, and `VERDICT playback=NA` (dictation logs hold no playback evidence). The logs carry no device UID on session or event lines, so events are matched to sessions by time window only. Live testing on a Bluetooth headset follows the protocol in [tools/live-protocol.md](tools/live-protocol.md).

### Unattended headset rig (`tools/rig/live-rig.zsh`, v1.14)

Runs the live A/B crossover without an operator: plays the recorded passage through the built-in speaker into the headset on the desk, performs ⌥⌥ through a test-only 0600 trigger file, and fills `tools/rig/out/table.md` (git-ignored). Live only on Raza's GO file; `--dry-run` replays the 10-13 crossover offline (`DRY-RUN PASS rows=11`). The host hooks are inert unless the host was launched with `DICTATE_RIG=1` and an absolute `DICTATE_RIG_DIR`; a host opts in with `engine.enableRig(launchEnvironment:gesture:)`. Details: [tools/live-ab-protocol.md §10](tools/live-ab-protocol.md).

## Embedding (DictateKit)

The `DictateKit` library product exposes the same engine to another app (`DictationEngine`, no pill or menu required). See [docs/HOSTING.md](docs/HOSTING.md), including the frozen `AudioRecorder` capture contract (v1.11) for hosts that run their own capture. Hosts should wire their single ⌥ tap to `engine.tap()` (it pre-starts the microphone) and tee `engine.onDiagnostic` into their own log.

## Keychain

Dictate reads the Groq API key from the login keychain item `groq-api` through `/usr/bin/security`, so rebuilding or re-signing the app never shows a keychain password dialog. If the key cannot be read, dictation still works with Apple on-device recognition and local cleanup (`fallback=no_key` in the log).

## Vocabulary hints

Teach Dictate domain-specific terms, technical names, or phonetic corrections:

1. Copy the sample file:
   ```bash
   mkdir -p "$HOME/Library/Application Support/Dictate"
   cp Resources/vocab-hints.sample.txt "$HOME/Library/Application Support/Dictate/vocab-hints.txt"
   ```
2. Edit `~/Library/Application Support/Dictate/vocab-hints.txt`. Format:
   ```text
   Term <- alias one, alias two
   Bare Term
   ```
   Lines with ` <- ` map comma-separated phonetic misrecognitions to the canonical term. A bare line is a term with no aliases. Comments starting with `#` and empty lines are ignored.
3. Hints are read at every dictation, so changes take effect immediately with no rebuild required.

## Files

- **Logs:**
  - `~/Library/Logs/Dictate/dictate.log`: One line per dictation recording timestamps and outcome status (never transcripts or spoken text).
  - `~/Library/Logs/Dictate/dictate.stderr.log`: LaunchAgent process stderr and diagnostic output.
- **State (`~/Library/Application Support/Dictate/`):**
  - `muted.state`: Mute-recovery state file used to restore audio if the app terminates abnormally.
  - `groq-quota.json`: Latest Groq rate-limit counts per endpoint (numbers and dates only).
  - `build.env`: Optional build environment overrides file.
  - `vocab-hints.txt`: Custom vocabulary terms and phonetic hints.

## Benchmarks (optional)

Run benchmarks via `tools/bench.sh`, which signs the benchmark binary and passes the Groq API key via the environment. The benchmark binary never reads the keychain itself: the `tools/bench.sh` wrapper fetches the key with the `security` tool and passes it in the environment.

Models: Groq cleanup for `cleanup` / `eval groq` is `qwen/qwen3.8-27b` (the cleanup bench always uses Groq); local cleanup for `cleanup-local` / `eval local` is `llama3.2:3b-instruct-q4_K_M`.

### Create a Test Audio Fixture
Create a 24 kHz mono PCM16 audio fixture without playing sound:
```bash
say -o /tmp/fixture.aiff "Your sentence here." && \
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/fixture.aiff /tmp/fixture16.wav && \
afconvert -f WAVE -d LEI16@24000 -c 1 /tmp/fixture16.wav /tmp/fixture.wav
```

### Benchmark Modes
- `tools/bench.sh stt-groq-chunked <wav> <runs>`
- `tools/bench.sh stt-apple <wav> <runs>`
- `tools/bench.sh stt-groq <wav> <runs>`
- `tools/bench.sh cleanup <model> <runs>`
- `tools/bench.sh cleanup-local <model> <runs>`
- `tools/bench.sh eval groq|local <model>`
- `tools/bench.sh levels <wav> new|old`
- `tools/bench.sh pill-match <wav>`
- `score-text` reads a transcript on stdin:
  ```bash
  echo "some text" | tools/bench.sh score-text
  ```

## Uninstall

To remove Dictate:

1. Run the uninstall script:
   ```bash
   tools/uninstall.sh
   ```
   *(Pass `--delete-app` to also remove the `~/Applications/Dictate.app` bundle.)*
2. Remove the stored Groq API key from your keychain:
   ```bash
   security delete-generic-password -s groq-api -a "$USER"
   ```
3. Remove permissions granted in **System Settings → Privacy & Security**.
4. Optionally delete application state and logs:
   ```bash
   rm -rf ~/Library/Application\ Support/Dictate ~/Library/Logs/Dictate
   ```
5. If wanted, remove the signing certificate: Keychain Access → login → My Certificates → delete "Dictate Dev" (or `security delete-identity -c "Dictate Dev"`).

## Coming from Wispr Flow

- **Before using Dictate:** Quit Wispr Flow and remove it from **System Settings → General → Login Items**. Both applications listen for **⌥⌥**, which causes double pasting if both are running.
- **To return to Wispr Flow:**
  1. Uninstall Dictate using `tools/uninstall.sh`.
  2. Reinstall or open Wispr Flow (download from [wisprflow.ai](https://wisprflow.ai) if needed):
     ```bash
     open -a "Wispr Flow"
     ```
  3. Re-add Wispr Flow to **System Settings → General → Login Items**.

## License

MIT (see [LICENSE](LICENSE)). Changelog is documented in [CHANGELOG.md](CHANGELOG.md).
