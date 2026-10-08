# Dictate

Standalone macOS dictation, replacing Wispr Flow. **Double-tap Left Option** (⌥ ⌥) to open the pill and talk, then **double-tap again** (or click ✓) to transcribe with OpenAI `gpt-4o-transcribe` and paste the text at the cursor. Your clipboard is put back afterwards. Press ✕ or Esc to cancel. Archie's ⌘⌘ is untouched.

## Usage
- ⌥⌥ starts recording. The pill sits bottom-centre on the screen with the mouse, and its bars follow your voice.
- ⌥⌥ again (or ✓) stops recording. The pill shows three pulsing dots while it transcribes, then the text is pasted at the cursor.
- ✕ or Esc discards the audio. Nothing is pasted.
- Recordings are capped at 5 minutes and finish automatically.
- Menu-bar mic: "Dictate (double-tap ⌥)", "Open log", "Quit".
- The API key is read on every use from the keychain (`security find-generic-password -w -s openai-api -a razakhan`).
- Vocabulary hints come from `~/.claude/projects/-Users-razakhan/memory/reference-raza-vocabulary.md` plus a fixed seed list.
- Log: `~/.claude/logs/dictate.log`, one line per dictation (time, duration, bytes, latency, chars, app, outcome). It never contains transcript text or the key. Diagnostics go to `~/.claude/logs/dictate.stderr.log`.
- Permissions: Accessibility (for the key tap and ⌘V) and Microphone, both for `Dictate.app`.

## Build / test / install
```
SW=~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift
"$SW" test                       # pinned toolchain only; Swift Testing
tools/make-app.sh                # -> ~/Applications/Dictate.app
tools/install-launchagent.sh     # -> ~/Library/LaunchAgents/com.razakhan.dictate.plist, loaded
```

## Uninstall
`tools/uninstall.sh` boots out the LaunchAgent and removes its plist. Add `--delete-app` to also delete `~/Applications/Dictate.app`.

## Roll back to Wispr Flow
1. `tools/uninstall.sh`
2. `open -a "Wispr Flow"`
3. `osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Wispr Flow.app", hidden:false}'`
