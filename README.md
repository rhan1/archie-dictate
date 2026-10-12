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
- `session=<id> event=start|end`: Correlates session lifecycle with `recording_ms=`, `capture_intervals=`, `speech_sections=`, `builtin_frames_after_fallback=`, and `builtin_backend=`.
- `builtin_backend=auhal`, `bridge_device_check=ok|drift|lost`: Status of the physical built-in capture unit.
- `fallback_check builtin_fresh_at_fallback=1|0`: Verifies built-in freshness when falling back from a silent headset.
- `headset_signal_start=1`: Confirms non-zero headset signal arrival.
- `bt_external_busy=1`, `bt_recovery=requested|queued|immediate|settled`: Bluetooth recovery episode decisions (`settled … result=frames|silent_frames|no_frames`).
- `bridge_switch=headset reason=recovered`: a recovered headset carries again after a fallback.
- `mute_reapplied=1 uid=… reason=default_changed|devices_changed|rate_changed`: the output mute flag was reset during the dictation (a headset profile flip) and set again; the timeline's `media=muted>restored(verified) mute_reapplied=<n>` counts them. `mute_unsupported_uid=…`: that output exposes no settable mute flag (volume is never touched).
- `speech_sections=` counts speech sections relative to the dictation's own noise floor (+12 dB, never below −60 dBFS), so a quiet built-in fallback still shows its speech.
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
3. **Speech evidence:** At least 3 speech sections (`speech_sections>=3`, runs of ≥300 ms with RMS ≥−40 dBFS separated by ≥200 ms).
4. **Transport recovery:** Every dropped eSCO link (`Dropping eSCO creation`) must either be re-created within 1.5 s followed by headset audio frames (`headset_signal_start=1`), or fall back onto a fresh built-in mic (`builtin_fresh_at_fallback=1`) that kept audio frames (`builtin_frames_after_fallback>0`).

Missing sessions, duplicate session IDs, missing outcomes, or log errors fail (`BT-PROOF: FAIL <reason>`). Live testing on a Bluetooth headset follows the protocol in [tools/live-protocol.md](tools/live-protocol.md).

## Embedding (DictateKit)

The `DictateKit` library product exposes the same engine to another app (`DictationEngine`, no pill or menu required). See [docs/HOSTING.md](docs/HOSTING.md). Hosts should wire their single ⌥ tap to `engine.tap()` (it pre-starts the microphone) and tee `engine.onDiagnostic` into their own log.

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
