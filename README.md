# Dictate

Standalone macOS dictation, replacing Wispr Flow. **Double-tap Left Option** (⌥ ⌥) to open the pill and talk, then **tap Left Option once** (or click ✓) to finish. Audio streams to OpenAI's Realtime `gpt-4o-transcribe` while you speak, a fast cleanup model tidies the text (fillers, self-corrections, punctuation, name spellings), and the result is pasted at the cursor. Your clipboard is put back afterwards. Press ✕ or Esc to cancel. Archie's ⌘⌘ is untouched.

## Usage
- ⌥⌥ starts recording. The pill sits bottom-centre on the screen with the mouse, and its bars follow your voice.
- One clean ⌥ tap (or ✓) finishes. ⌥ chords such as ⌥← while recording are ignored. The pill shows three pulsing dots until the text is pasted.
- Cleanup never adds content. If it errors or takes over 2.5 s, the raw transcript is pasted (`cleanup=skipped:<reason>` in the log). If the Realtime socket can't open within 1.5 s, the v1 batch upload is used (`path=batch`).
- ✕ or Esc discards the audio. Nothing is pasted.
- Recordings are capped at 5 minutes and finish automatically.
- Menu-bar mic: "Dictate (double-tap ⌥)", "Open log", "Quit".
- The API key is read on every use from the keychain (`security find-generic-password -w -s openai-api -a razakhan`).
- Vocabulary hints come from `~/.claude/projects/-Users-razakhan/memory/reference-raza-vocabulary.md` plus a fixed seed list.
- Log: `~/.claude/logs/dictate.log`, one line per dictation (time, duration, bytes, latency, chars, app, outcome, plus `path`, `stt_ms`, `cleanup_ms`, `model`, `cleanup`). It never contains transcript text or the key. Diagnostics go to `~/.claude/logs/dictate.stderr.log`.
- Permissions: Accessibility (for the key tap and ⌘V) and Microphone, both for `Dictate.app`.

## Build / test / install
```
SW=~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift
"$SW" test                       # pinned toolchain only; Swift Testing
tools/make-app.sh                # -> ~/Applications/Dictate.app
tools/install-launchagent.sh     # -> ~/Library/LaunchAgents/com.razakhan.dictate.plist, loaded
"$SW" run -c release DictateBench stt-realtime <24k.wav> 5   # G6 latency harness (also stt-batch, cleanup <model> <runs>)
```

## Uninstall
`tools/uninstall.sh` boots out the LaunchAgent and removes its plist. Add `--delete-app` to also delete `~/Applications/Dictate.app`.

## Roll back to Wispr Flow
1. `tools/uninstall.sh`
2. `open -a "Wispr Flow"`
3. `osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Wispr Flow.app", hidden:false}'`
