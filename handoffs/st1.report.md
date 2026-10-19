# ST1 streaming dictation

IN PROGRESS. Five numbered build deliverables; scripted tests accompany their corresponding steps. No delegation, network, key reads, audio, browser, or bench execution.

1. DONE WebSocket seam: injectable binary/text connection and URLSession production transport; EngineDependencies default. Lease build passed (11.92 s).
2. DONE Streaming transcriber: exact nova-3 URL, escaped/capped keyterms via AppPaths, binary PCM, final-only callbacks, idempotent finish, fixed virtual 1500 ms close deadline. Hand-written JSONL fixture. Lease filtered tests: 4 tests in 1 suite passed (0.005 s). Positive final callback arrived before stop; negative controls rejected two interims and empty final; a final at virtual +1200 ms survived CloseStream. Missing file gives zero terms; cap excludes term 51. Close verified exactly once at virtual 1500 ms.
3. DONE Whole-WAV fallback: retained PCM encoded with WAVEncoder (24000 Hz) and sent once through existing TranscriptionClient. Recorder PCM override supported; app wiring follows in step 4. Logs contain only fixed fallback reasons. Missing-key, connect, socket, and virtual receive-timeout tests each prove exactly one request, complete WAV bytes (including audio after failure), correct endpoint/auth/prompt, and no duplicate streaming callbacks. Concurrent/repeated finish is idempotent. Successful stream and cancelled run prove zero fallback requests. Lease filtered tests: 9 tests in 1 suite passed (0.007 s).
4. NOT-DONE Selection and host plumbing.
5. NOT-DONE Bench and final filtered verification.

RED baseline: the new tests reference DeepgramStreamingTranscriber, absent on 123565f, so cannot compile there. Manager verifies the base separately without stashing.
