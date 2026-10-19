# ST1 streaming dictation

DONE — all five numbered deliverables implemented. Production build passed through the Swift lease; final filtered run passed 32 tests in two suites. No delegated work, network calls, actual key reads, audio/device operations, application launch, or bench execution.

1. DONE WebSocket seam: injectable connect/binary/text/receive/close with production URLSession transport; EngineDependencies production default. Upgrade cancellation closes the pending task.
2. DONE Deepgram nova-3: exact listen URL and auth header, AppPaths/injectable keyterms, first 50 physical lines, percent encoding, final-only monotonic callbacks, single-space join, idempotent finish and fixed 1500 ms virtual close deadline.
3. DONE Fallback: missing key, connect failure, socket error, and receive timeout each trigger one whole-WAV request through the existing TranscriptionClient. AppController supplies recorder-retained PCM. Count-only fallback notes contain fixed reasons. Failed streaming partials never get appended to the whole-WAV replacement.
4. DONE Selection: public DictationSTT values groq/deepgram and defaulted DictationEngine arguments. Default engine and explicit selection tested by constructing public engines without starting them. Host tap/start prefetch Deepgram through KeyStore. Successful Deepgram feeds the existing cleaner/stop-phrase/delivery pipeline; whole-WAV replacement uses single cleanup. Existing Groq attachment branch mechanically compared with 123565f: byte-for-byte identical. Isolated quota paths no longer initialize the home-directory shared quota store merely to compare paths. Core tests link AppKit only to exercise the public host constructor and EnginePolicy, without starting capture.
5. DONE Bench: stt-deepgram-streaming reads DEEPGRAM_API_KEY using requireKey; both streaming commands print first_text_ms, final_after_end_ms and per-run transcripts. PCM is paced in 2400-sample/100 ms chunks; absent first callback reports -1. Existing Groq tail controls are preserved. Bench compiled and was not run.

Verification:
- Final lease build: Build complete! (0.15s).
- Exact requested filter DeepgramStreamingTranscriberTests|GroqChunkedTranscriber: 10 tests passed (0.007 s).
- The existing Groq suite display name does not match its Swift type; additional --filter GroqChunkedTests passed all 22 tests.
- Final combined filter DeepgramStreamingTranscriberTests|GroqChunkedTranscriber|GroqChunkedTests: Test run with 32 tests in 2 suites passed after 0.299 seconds.
- Scripted JSONL is hand-written from documented Results shape, explicitly identified in the first test-file comment. Positive control: final callback before stop. Negative controls: two interims and an empty final rejected. Stop occurs at virtual 14900 ms; the old 15000 ms recording watchdog must not discard a final received at stop +1200 ms. No-final close completes at 1500 virtual ms with exactly one CloseStream. Whole-WAV assertions include post-failure audio, recorder PCM override, auth, endpoint, vocabulary, and exactly one request under concurrent finish. Successful and cancelled runs prove zero fallback requests.
- No hard-coded user/home paths in new transport/transcriber/selection/test/fixture files; git diff --check passed. No browser or live-endpoint verification under the offline/hardware constraints; manager handles any visual verification.

Literal final test output:
```text
ST1 URL keyterms=3 model=nova-3 sample_rate=24000
ST1 URL keyterms=50 model=nova-3 sample_rate=24000
ST1 CANCEL groq_requests=0 closestream=0
ST1 FALLBACK reason=missing_key groq_requests=1 lost=0
ST1 FALLBACK reason=connect groq_requests=1 lost=0
ST1 SELECT default=groq
ST1 CLOSE closestream=1 waited_ms<=1500
ST1 GREEN finals=2 before_stop=1 late_final=1 interim_ignored=2
ST1 FALLBACK reason=timeout groq_requests=1 lost=0
ST1 FALLBACK reason=socket groq_requests=1 lost=0
```

RED baseline: Tests/DictateCoreTests/DeepgramStreamingTranscriberTests.swift cannot compile on 123565f (no DeepgramStreamingTranscriber). Manager verifies that baseline; no stash or base worktree mutation was used.

Cleanup: no new worktrees or external scratch artifacts. git worktree list shows only the original checkout and this provided worktree. Test temporary fixtures remove themselves. Own build/test scratch logs removed after preserving evidence here; retained standard ignored Swift build cache measured 564M. Only this report remains under handoffs.

Files changed:
- Package.swift
- Sources/DictateAppKit/AppController.swift
- Sources/DictateAppKit/DictationEngine.swift
- Sources/DictateAppKit/EngineDependencies.swift
- Sources/DictateAppKit/EngineTranscribers.swift
- Sources/DictateBench/main.swift
- Sources/DictateCore/AppPaths.swift
- Sources/DictateCore/DeepgramStreamingTranscriber.swift
- Sources/DictateCore/DictationSTT.swift
- Sources/DictateCore/WebSocketTransport.swift
- Tests/DictateCoreTests/DeepgramStreamingTranscriberTests.swift
- Tests/DictateCoreTests/Fixtures/deepgram-nova3-frames.jsonl
- handoffs/st1.report.md
