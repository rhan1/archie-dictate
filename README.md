# Dictate

Dictate is a standalone menu-bar dictation app for macOS. Speak into any app, then finish with a tap: Dictate transcribes your speech, removes filler words and spoken corrections, and pastes the result at your cursor.

Speech recognition defaults to `groq-chunked` (Groq `whisper-large-v3-turbo`), with Apple on-device as the fallback for failed chunks; set `DICTATE_STT=apple` for Apple-only speech recognition. Cleanup uses Groq `qwen/qwen3.8-27b`, then local Ollama; if both cleaners fail, Dictate pastes the raw transcript. If neither speech recognizer returns text, the pill shows “no speech”.

## Requirements and setup

You need macOS 26, an Apple Silicon Mac, a microphone, and the Swift 6.3.3 release toolchain. Download the macOS toolchain installer from [swift.org](https://www.swift.org/install/) and install it at `~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain`. All commands below use that toolchain explicitly.

Install [Homebrew](https://brew.sh/) if needed, then prepare the offline cleanup fallback:

```bash
brew install ollama && brew services start ollama && ollama pull llama3.2:3b-instruct-q4_K_M
```

Create a Groq API key at [console.groq.com](https://console.groq.com/keys). Store it in your login keychain with your current macOS username as the account. Replace `<key>` below with the key, keeping the quotes (do not type the angle brackets):

```bash
security add-generic-password -s groq-api -a "$USER" -w '<key>'
```

Dictate prefetches this key on a background queue at launch. An unanswered keychain dialog never blocks a dictation: until the key is available, cloud requests skip immediately. The cache is held only in memory until you quit; a denied read can retry after 60 seconds. Restart Dictate after replacing an already cached key.

## Build, test and install

Run these commands from your checkout:

```bash
cd /path/to/dictate
SW=~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift
"$SW" build --product Dictate
"$SW" test
DICTATE_SWIFT="$SW" tools/make-app.sh
```

The last command creates `~/Applications/Dictate.app`. Quit Wispr Flow before opening Dictate. Launch the app:

```bash
open "$HOME/Applications/Dictate.app"
```

On first launch, grant **Accessibility** and **Microphone** to **Dictate.app** in **System Settings → Privacy & Security**. If macOS asks whether “Dictate” can use `groq-api`, select **Always Allow**. Apple speech assets may need to download on first use. If the hotkey initially does nothing, let the app finish acquiring Accessibility permission.

To run Dictate at login with stderr captured in its log, install the LaunchAgent after the app is built:

```bash
tools/install-launchagent.sh
```

This command starts the installed app. Quit a manually launched copy first.

## Usage and recovery

Use the **left** Option key. A clean tap means pressing and releasing it without another key or modifier.

- **⌥⌥** starts recording. The first tap prepares the microphone and warms cleanup. Grey bars mean the microphone is warming; white bars follow your voice.
- **One ⌥ tap** or **✓** finishes recording. The dots mean transcription is running.
- **✕** or **Esc** cancels recording or dismisses an outcome pill.
- **held** means focus changed between recording and paste. The text stays on the clipboard and in memory. Focus the app where you want it, then click the clipboard **✓** or tap **⌥ once** to paste it there exactly once. Recovery waits for the double-tap window to close.
- **⌥⌥ while held** dismisses the held pill and starts a new dictation.
- An error pill shows **no key**, **timeout**, **offline**, or **error**. Held and error pills stay for up to **20 seconds**. The recovery button does nothing if there is no text; **no speech** means neither recognizer produced a transcript.
- **raw** appears for **1.5 seconds** when cleanup fails; the raw text has already been pasted.
- **Paste last dictation** in the menu-bar microphone menu recovers the most recent held text for **10 minutes**, even after dismissing the pill.

Dictate normally pastes into the app you started in. If you start while a system permission dialog or Dictate itself is frontmost, it pastes into whichever app is frontmost at insertion time. Recovery also uses the app frontmost at insertion time. The previous clipboard is restored after about one second unless you copied something else meanwhile.

## Vocabulary, audio and logs

Edit `Resources/vocab-hints.txt` to teach cleanup how names sound, one hint per line, such as `DB99 <- he beat 99, dee bee ninety-nine`. The running app reloads the editable file from `~/Projects/dictate/Resources/vocab-hints.txt` when present; otherwise it uses the copy bundled by `tools/make-app.sh`, so rebuild for edits in other checkout locations. Hints affect cleanup, not speech recognition. A personal vocabulary file, when present at `~/.claude/projects/-Users-razakhan/memory/reference-raza-vocabulary.md`, supplements the seed terms; coworkers can use the hints file without that personal file.

While recording, Dictate mutes the system output using its mute flag while media keeps playing. It restores mute when recording ends, on quit, and after a crash at the next launch. Devices without a mute flag use media pausing instead. Bluetooth microphones can take time to switch profiles.

Logs contain timing, counts and outcome reasons; they never contain transcript text or key values:

- `~/.claude/logs/dictate.log`: one entry per dictation.
- `~/.claude/logs/dictate.stderr.log`: LaunchAgent diagnostics, per-dictation timelines and `keys=groq:ok|pending|denied` states. A manual launch writes these diagnostics to its stderr.

Use **Open log** in the menu or inspect the files in a terminal.

## Benchmarks

`tools/bench.sh` builds and signs the harness with the pinned toolchain, loads the Groq key for cloud modes and runs a benchmark. Cloud benchmarks use your Groq quota; they are separate from the network-free Swift Testing suite. Local and Apple modes require no cloud key. Supply a real speech WAV fixture for transcription measurements; the harness expects 24 kHz mono PCM16.

```bash
tools/bench.sh stt-apple /path/to/speech.wav 5
tools/bench.sh stt-groq /path/to/speech.wav 5
tools/bench.sh cleanup qwen/qwen3.8-27b 5
tools/bench.sh cleanup-local llama3.2:3b-instruct-q4_K_M 5
tools/bench.sh eval groq qwen/qwen3.8-27b
tools/bench.sh eval local llama3.2:3b-instruct-q4_K_M
```

Additional harness modes include `stt-groq-chunked`, `levels`, `pill-match`, and `score-text`. The app defaults to `groq-chunked` with Apple on-device fallback; `DICTATE_STT=apple` selects Apple-only speech recognition.

## Known limits

`tools/make-app.sh` signs with the persistent identity named by `DICTATE_SIGNING_IDENTITY`, default **Archie Dev**. Coworkers should set that variable to their own persistent code-signing identity. If none is available, the script uses ad-hoc signing, and macOS re-asks for Accessibility and Microphone permissions after every rebuild. Rebuild, then restart the installed app to use code changes.

Ollama must be running with the named model downloaded for offline cleanup. Dictate warms the model at launch and on the initial Option tap with a two-second request, but loading can still fail or exceed that timeout. If Apple speech assets are unavailable and Groq is offline, no transcript can be recovered. Cleanup can make mistakes; check text before sending it.

Never run Wispr Flow and Dictate together: both listen for ⌥⌥ and can paste twice.

## Uninstall or return to Wispr Flow

Quit Dictate, then remove its login agent:

```bash
tools/uninstall.sh
```

Add `--delete-app` to also remove `~/Applications/Dictate.app`. Logs are left in place. To return to Wispr Flow after uninstalling:

```bash
open -a "Wispr Flow"
```

Add Wispr Flow back in **System Settings → General → Login Items** if you want it to start at login. You may also remove Dictate's permission entries under **Privacy & Security** and delete the `groq-api` keychain entry if nothing else uses it.
