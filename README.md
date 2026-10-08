# Dictate

Dictate is a menu-bar dictation application for macOS. Press **⌥⌥** (double-tap Option) to start recording, speak naturally in any application, and tap **⌥ once** (or click the checkmark) to finish—Dictate transcribes your speech via Groq, cleans up filler words and spoken self-corrections, and pastes the result directly at your cursor. Audio output is automatically muted while you talk (using the macOS mute flag, leaving system volume unchanged) and restored when you finish. If network or cloud services are unavailable, Dictate automatically falls back to Apple on-device speech recognition and local Ollama cleanup.

## Quick start

1. Get a Groq API key at [console.groq.com](https://console.groq.com).
2. Store the key in your login keychain: `security add-generic-password -s groq-api -a "$USER" -w '<your-groq-key>'`
3. Install Ollama and start the fallback cleanup model: `brew install ollama && brew services start ollama && ollama pull llama3.2:3b-instruct-q4_K_M`
4. Install the Swift 6.3.3 toolchain from [swift.org](https://www.swift.org/install/) to `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain`.
5. Create the signing identity: `tools/ensure-signing-identity.sh`
6. Build the application bundle: `tools/make-app.sh`
7. Install and launch the agent: `tools/install-launchagent.sh`
8. Grant **Microphone** and **Accessibility** permissions to `Dictate.app` in **System Settings → Privacy & Security**.
9. When prompted with a keychain dialog for "Dictate", click **Always Allow**.
10. Press **⌥⌥** anywhere to try it.

## Requirements

- **Operating System & Architecture:** macOS 26 on an Apple Silicon Mac.
- **Xcode Command Line Tools:** Required for the SDK and linker (`xcode-select --install`).
- **Swift 6.3.3 Toolchain:** Download the macOS package installer from [swift.org](https://www.swift.org/install/) and install it to `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain`. That path is what the build and bench scripts (`tools/*.sh`) use.
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

Example `~/Library/Application Support/Dictate/build.env`:
```bash
DICTATE_SIGNING_IDENTITY="Dictate Dev"
DICTATE_BUNDLE_ID="dev.dictate.app"
DICTATE_LABEL="dev.dictate.app"
```

## Permissions

Configure the following permissions in macOS:

1. **Microphone & Accessibility:** Grant permissions to `Dictate.app` under **System Settings → Privacy & Security → Microphone** and **System Settings → Privacy & Security → Accessibility**.
2. **Input Monitoring:** If the hotkey does nothing even with Accessibility granted, also grant `Dictate.app` access under **System Settings → Privacy & Security → Input Monitoring** (macOS occasionally requires this for listen-only event taps).
3. **Keychain Access:** When the macOS dialog asks for access to the `groq-api` keychain item naming **"Dictate"**, choose **Always Allow**. If a dialog appears naming **"DictateBench"**, select **Deny** (benchmark runs provide keys via the environment rather than keychain prompts).

## Usage

Use the **left Option** key (press and release cleanly without other modifier keys):

- **Start Recording:** Press **⌥⌥** (double-tap Option). Grey bars appear while the microphone warms up, followed by white bars when listening to your voice.
- **Finish Recording:** Tap **⌥ once** or click **✓**. Dictate transcribes the audio, runs cleanup, and pastes the text directly at your cursor.
- **Cancel:** Press **Esc** or click **✕** to cancel recording or dismiss a pill.
- **Held & Status Outcomes:** If a paste cannot land immediately (such as when switching apps during processing or when a service fails), the pill remains on screen for up to **20 seconds** displaying a status word (e.g., `held`, `no key`, `timeout`, `offline`, `error`).
  - Clicking **✓** or tapping **⌥ once** pastes the text into your active application.
  - The menu-bar microphone icon's **"Paste last dictation"** menu item retains the text for up to **10 minutes** in memory (RAM only, never saved to disk).
- **Audio Output Muting:** Output audio is automatically muted while you talk (toggling the hardware mute flag only, never altering the volume slider) and restored immediately afterwards, including after a crash upon next launch.

## Engine

- **Default (`groq-chunked`):** Audio is uploaded in short chunks while you talk, minimizing latency when dictation ends.
- **Automatic Fallback:** Apple on-device speech recognition (`Speech.framework`) serves as the automatic fallback if Groq chunk uploads fail.
- **Force Apple-Only STT:** To force Apple on-device recognition for the LaunchAgent, set `DICTATE_STT=apple`:
  ```bash
  # Ensure the EnvironmentVariables dictionary exists:
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" ~/Library/LaunchAgents/<label>.plist 2>/dev/null || true

  # Set DICTATE_STT to apple:
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:DICTATE_STT string apple" ~/Library/LaunchAgents/<label>.plist

  # Restart the LaunchAgent:
  launchctl kickstart -k "gui/$UID/<label>"
  ```
  *(Replace `<label>` with your LaunchAgent label, default `dev.dictate.app`.)*

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
  - `build.env`: Optional build environment overrides file.
  - `vocab-hints.txt`: Custom vocabulary terms and phonetic hints.

## Benchmarks (optional)

Run benchmarks via `tools/bench.sh`, which signs the benchmark binary and passes the Groq API key securely via the environment:

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
- `BENCH_GROQ=1 tools/bench.sh cleanup <model> <runs>`
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
