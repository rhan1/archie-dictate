# H1 voice processing fallback

NOT-DONE — deliverable 1/3: offline reproduction in progress.

Scope: wt/dictate-v20 at 1e1c687. Three deliverables: offline reproduction; fallback implementation and controls; final filtered verification. No hardware, devices, live apps, other worktrees, external dispatch, or home-path writes.

Hypothesis: silent VP aggregate input can explain the reported no_input → mic_dead chain. Offline fixtures can prove policy behavior under that condition, not the OS cause of buffer starvation.

DONE — deliverable 1/3: historical reproduction before production changes.
- Added H1VoiceProcessingFallbackTests fixture: enabling VP changes the fake hardware to 48000 Hz/9ch, supplies zero buffers; real CaptureVoiceProcessing selects on; real CaptureFeed/CaptureHealth warns no_input at virtual 1.1 s and fails mic_dead at 2 s, while real CaptureLifecycle is warming.
- Verified with leased test --filter 'H1VoiceProcessingFallbackTests': 1 test in 1 suite passed. Literal receipt: `H1 RED vp_requested=1 hw_channels=9 buffers=0 outcome=mic_dead`.
- This is a passing characterization of the bad pre-fix behavior, not a deliberately broken test suite. It establishes the policy failure chain, not why macOS stopped supplying callbacks.

NOT-DONE — deliverable 2/3: implement multichannel refusal and same-capture silent VP recovery, then controls.

DONE — deliverable 2/3: fallback implementation and required controls.
- CaptureInputUnit now exposes post-configure hardware channels; >2 refuses before VP start, disposes its graph, starts plain, and reports fallback/multichannel_input. Existing refusals and Bluetooth remain unavailable.
- Recorder health intercepts the silent VP deadline before mic_dead, invalidates the old tap, and queues one plain graph replacement on its existing executor. Health pauses during replacement, then gives plain input a fresh 2 s window. Recording boundary, duration, feed/evidence, epoch and lease remain intact. Configuration retaps keep fallback latched; lifecycle's 3 s retry yields to recorder health.
- Added hardware-free recorder fixture methods using the real policy, capture lease, health/feed and same replacement path. Virtual scheduler tests prove 9ch rejection, mono no-buffer recovery, healthy mono VP, Bluetooth, dictation, and failure when plain is also silent. Historical RED explicitly disables only the multichannel guard and retains original health evaluation.
- Verification: leased test --filter 'H1VoiceProcessingFallbackTests|C1VoiceProcessingTests|CaptureHealth|InjectedHealth|CaptureLifecycle': 77 tests in 5 suites passed after 0.259 seconds. git diff --check passed.
- First build caught missing public TickOutput initializer; fixed before passing verification. No devices, live apps, or real home paths used by fixtures.

NOT-DONE — deliverable 3/3: final required filtered run (including WAVInjected), merge-base diff review and cleanup/status receipts.
