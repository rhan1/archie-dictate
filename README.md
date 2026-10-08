# Dictate

Standalone macOS dictation app replacing Wispr Flow. Double-tap Left Option (⌥⌥) starts; ONE clean ⌥ tap (or ✓) finishes; ✕ or Esc cancels. Archie's ⌘⌘ is untouched. Menu-bar mic: "Dictate (double-tap ⌥)", "Paste last dictation", "Open log", "Quit".

## Pill
- Wispr-sized (102×30 pt, 1 pt outline, 10 bars) bottom-centre of the mouse's screen, 14 pt above the bottom.
- Grey WARMING bars until the mic delivers audio (Bluetooth headsets need ~0.2–2 s to switch).
- White live bars that grow/shrink in place with your voice.
- Three dots while transcribing; red ✕ on error.

## Pipeline
- Mic engine starts on the FIRST ⌥ tap (hides headset warm-up) → Apple on-device speech recognition (SpeechAnalyzer, macOS 26) streaming while you talk (~20–50 ms after the finish tap) → fallback batch Groq whisper-large-v3-turbo → batch OpenAI gpt-4o-transcribe.
- Then a cleanup pass (fillers, self-corrections, punctuation, list colons, names from the vocabulary) on Groq qwen/qwen3.8-27b → fallback local Ollama llama3.2:3b-instruct → else the raw transcript.
- Cleanup never adds content; truncated/filtered responses or a length change beyond 0.5×–1.5× are rejected (raw text pasted).
- Measured end-to-end ~0.35–0.6 s from finish tap to paste.

## Insertion
- Pasted with ⌘V into the app you STARTED in; if focus moved to a different app, nothing is pasted — the text stays on the clipboard and in "Paste last dictation" (memory only, 10 min).
- The previous clipboard is restored ~1 s later only if nothing else was copied meanwhile.

## Audio
- While you talk the system output is MUTED (mute flag only, never the volume level); media keeps playing silently.
- Mute is restored on every end path, on quit, and on the next launch after a crash (state file ~/.claude/run-status/dictate-muted).
- Devices without a mute flag fall back to pausing media.

## Keys & Requirements
- Keys (macOS keychain, read in-process at use time): `groq-api` (account razakhan) and `openai-api` (account razakhan).
- Vocabulary hints: ~/.claude/projects/-Users-razakhan/memory/reference-raza-vocabulary.md (meaning column) + a fixed seed list.
- Requirements: macOS 26, Accessibility + Microphone permission for Dictate.app, Ollama running locally (brew services) for the offline cleanup fallback.

## Logs
- ~/.claude/logs/dictate.log one line per dictation (time, duration, bytes, latency_ms, chars, app, outcome, path, stt_ms, cleanup_ms, model, cleanup) — never the text.
- ~/.claude/logs/dictate.stderr.log has a per-dictation `timeline:` line.

## Build, Test & Install
Pinned toolchain:
```bash
SW=~/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift
"$SW" test
tools/make-app.sh            # -> ~/Applications/Dictate.app
tools/install-launchagent.sh # -> LaunchAgent com.razakhan.dictate
```

## Benchmarks
Harness (`"$SW" run -c release DictateBench …`):
- `stt-apple <wav> <runs>`
- `stt-groq <wav> <runs>`
- `stt-batch <wav> <runs>`
- `cleanup <model> <runs>` (BENCH_GROQ=1 for Groq)
- `cleanup-local <model> <runs>`
- `eval groq|local|cloud <model>` (10-case quality eval)
- `levels <wav> new|old` (pill amplitude gate)
- `score-text` (stdin)

Fixtures are generated with the non-audible `say -o file.aiff` + `afconvert`.

## QA Levers
- DICTATE_FAKE_TRANSCRIPT
- DICTATE_PILL_HIDE=1
- DICTATE_TRACE=1
- DICTATE_DEMO_LEVELS=1

## Uninstall & Wispr Rollback
- Uninstall: `tools/uninstall.sh` (add `--delete-app` to remove the bundle).
- Roll back to Wispr Flow in 3 lines:
  1) tools/uninstall.sh
  2) open -a "Wispr Flow"
  3) add Wispr Flow back under System Settings → General → Login Items

Never run Dictate and Wispr together (both answer ⌥⌥ → double paste).
