# Changelog
- v1.0 — ⌥⌥ dictation app replacing Wispr Flow: pill, OpenAI batch transcription, clipboard paste, LaunchAgent.
- v1.1 — single ⌥ finish, cleanup pass, Wispr-sized pill, Bluetooth warm-up, output mute while talking, Apple on-device STT.
- v1.2 — review fixes: insertion target lock, safe clipboard restore, truncated-cleanup rejection, one cleanup client, in-process keychain, Wispr pill motion.
- v1.3 — Groq chunked streaming STT as default, Groq cleanup with local Ollama fallback, OpenAI removed, persistent held/error pill.
- v1.4 — publish prep: standard macOS paths with migration, configurable signing identity and bundle id, generic vocabulary sample, LICENSE.
- v1.5 — mic never wedges: Objective-C exceptions from AVAudioEngine are caught, one teardown for every end path, rebuild → retry → built-in microphone fallback, first-buffer watchdog (red-team: 33 lifecycle scenarios); pill status words ("no mic", "no key", "offline", "timeout", "held", "no speech") with the paste button only when text exists; first chunk 3–4 s and a filler-aware Whisper prompt; incremental cleanup during speech for long dictations; trailing-silence trim against Whisper hallucinations.
