# ST1 streaming dictation

IN PROGRESS. Five numbered build deliverables; scripted tests accompany their corresponding steps. No delegation, network, key reads, audio, browser, or bench execution.

1. DONE WebSocket seam: injectable binary/text connection and URLSession production transport; EngineDependencies default. Lease build passed (11.92 s).
2. NOT-DONE Streaming transcriber and scripted finals/URL/close tests.
3. NOT-DONE Whole-WAV fallback and failure tests.
4. NOT-DONE Selection and host plumbing.
5. NOT-DONE Bench and final filtered verification.

RED baseline: the new tests reference DeepgramStreamingTranscriber, absent on 123565f, so cannot compile there. Manager verifies the base separately without stashing.
