# H1 voice processing fallback

NOT-DONE — deliverable 1/3: offline reproduction in progress.

Scope: wt/dictate-v20 at 1e1c687. Three deliverables: offline reproduction; fallback implementation and controls; final filtered verification. No hardware, devices, live apps, other worktrees, external dispatch, or home-path writes.

Hypothesis: silent VP aggregate input can explain the reported no_input → mic_dead chain. Offline fixtures can prove policy behavior under that condition, not the OS cause of buffer starvation.

DONE — deliverable 1/3: historical reproduction before production changes.
- Added H1VoiceProcessingFallbackTests fixture: enabling VP changes the fake hardware to 48000 Hz/9ch, supplies zero buffers; real CaptureVoiceProcessing selects on; real CaptureFeed/CaptureHealth warns no_input at virtual 1.1 s and fails mic_dead at 2 s, while real CaptureLifecycle is warming.
- Verified with leased test --filter 'H1VoiceProcessingFallbackTests': 1 test in 1 suite passed. Literal receipt: `H1 RED vp_requested=1 hw_channels=9 buffers=0 outcome=mic_dead`.
- This is a passing characterization of the bad pre-fix behavior, not a deliberately broken test suite. It establishes the policy failure chain, not why macOS stopped supplying callbacks.

NOT-DONE — deliverable 2/3: implement multichannel refusal and same-capture silent VP recovery, then controls.
