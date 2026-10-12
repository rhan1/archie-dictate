# Live Protocol — DictateKit v1.8

This document defines the live verification protocol executed exclusively by Raza after Archie v34 pins DictateKit v1.8. Nobody else runs this protocol.

> [!IMPORTANT]
> DictateKit v1.8 is unproven on a Bluetooth headset until this live protocol passes. Do not claim verification on hardware beforehand.

---

## 1. Preconditions

Before beginning the test runs, verify and record the system environment:

1. **Exact Installed Build:**
   - Log the host application (`Archie.app` v34 or standalone `Dictate.app`).
   - Log the DictateKit git commit hash:
     ```bash
     git rev-parse HEAD
     ```
   - Log the macOS operating system version and build:
     ```bash
     sw_vers
     ```
2. **Headset Hardware:**
   - Sony WH-1000XM6 Bluetooth headset paired and connected.
3. **Headset Audio Profile Precondition:**
   - Start each cold run only after `bt_profile=a2dp` is confirmed in `~/Library/Logs/Dictate/dictate.stderr.log` or the unified log:
     ```text
     bt_after3s=a2dp bt_profile=a2dp engine_allocated=false
     ```
   - Verify that output audio is playing at high quality (A2DP) before initiating cold test runs.

---

## 2. Test Passage and Markers

During each recording, speak the following fixed passage verbatim (20–30 seconds):

> "Hey — um, so for the Politrace launch, send the draft to the team on Tuesday, no, Wednesday. [pause two full seconds] We need, like, three things: the Limpar match counts, the DB99 query, and, uh, the screenshots. Can you also check if TurnoutWatch is still running? Thanks."

### Transcript Markers

- **First Marker:** `"Hey"`
- **Middle Marker:** `"Politrace"`
- **Last Marker:** `"Thanks"`

### Expected Cleaned Paste

The cleanup pipeline must yield the following canonical text:

> "Hey, so for the Politrace launch, send the draft to the team on Wednesday. We need three things: the Limpar match counts, the DB99 query, and the screenshots. Can you also check if TurnoutWatch is still running? Thanks."

### Health Clock Pause Requirement

The intentional two-second pause (`[pause two full seconds]`) between sentences tests that the 100 ms health clock does not falsely flag silence or trigger `fail reason=mic_dead` during natural conversational pauses.

---

## 3. Run Matrix

Execute the following eight runs in order:

| Run | Type | Description |
|---|---|---|
| **R1** | Cold start | Cold A2DP→HFP transition, no competing media client running. |
| **R2** | Cold start | Cold A2DP→HFP transition, no competing media client running. |
| **R3** | Cold start | Cold A2DP→HFP transition, no competing media client running. |
| **R4** | Contention | Cold A2DP→HFP transition with Google Chrome playing background audio to the headset. |
| **R5** | Contention | Cold A2DP→HFP transition with Google Chrome playing background audio to the headset. |
| **R6** | Contention | Cold A2DP→HFP transition with Google Chrome playing background audio to the headset. |
| **R7** | Repeat after cancel | Trigger ⌥⌥, press Esc/cancel, then immediately double-tap ⌥⌥ and dictate the passage. The cancelled session is reported `CANCELLED (excluded)` by bt-proof; the repeat must PASS. |
| **R8** | Built-in control | Headset powered off / disconnected; recording performed solely on the physical built-in mic. |

---

## 4. Per-Run Verification Checks

Every individual run (R1–R8) must satisfy all of the following checks:

1. **Markers Present:** All three markers (`"Hey"`, `"Politrace"`, and `"Thanks"`) are present in the pasted text (or verified held text if focus moved).
2. **Single Paste:** Exactly one paste lands in the active application; no duplicate text or missing insertions.
3. **Proof Tool Verdict:** Run `tools/bt-proof.sh --log-window '<run start>' '<run end>'`. It must output:
   ```text
   BT-PROOF: PASS
   ```
   (confirming ≥95 % coverage after 1 s startup allowance, no gaps >600 ms, ≥3 speech sections, and successful eSCO recreation or fresh built-in fallback).
4. **Built-in AUHAL owned and delivering (R1–R7; R8 has no bridge because the built-in is the default input):**
   - the start line `builtin_backend=auhal device=<id> bridge_device_check=ok` appears, and never a `bridge_device_check=drift …`, `bridge_device_check=lost` or `bridge_builtin_lost=1` line;
   - `tap2_to_first_kept_buffer_ms=… kept_src=builtin` (or `kept_src=ring`) shows the AUHAL delivered;
   - no child IOProc on the aggregate: in the raw `log show` of the window there is no `caller requesting device change from <built-in id> to <aggregate id>` for any AUHAL after that start line (the 21:33 signature).
5. **No False Mic Death:** No `fail reason=mic_dead` line is logged during the two-second conversational pause.
6. **Clean Resource Teardown:** Three seconds after dictation ends, resources are fully released:
   ```text
   bt_after3s=a2dp bt_profile=a2dp engine_allocated=false
   ```

---

## 5. Results Table

Record the outcome of each run in the following table:

| Run | Time Window | Outcome | bt-proof Line | Path Used (`headset` \| `builtin fallback`) | Notes |
|---|---|---|---|---|---|
| **R1** | | | | | |
| **R2** | | | | | |
| **R3** | | | | | |
| **R4** | | | | | |
| **R5** | | | | | |
| **R6** | | | | | |
| **R7** | | | | | |
| **R8** | | | | | |

---

## 6. Reporting and Archival Rules

1. **Independent Path Reporting:**
   - Report **"fallback continuity passed"** separately from **"headset transport recovery passed"**.
   - Do not conflate built-in fallback resilience with successful headset Bluetooth transport recovery.
2. **Explicit Unexercised Status:**
   - Any path or condition not directly exercised by a run must be recorded as **"unexercised"** rather than assumed passing.
3. **Same-Day Log Archival:**
   - On the same day the protocol is run, archive both:
     - The complete output of `tools/bt-proof.sh --log-window '<run start>' '<run end>'` for each run.
     - The raw unified log dump extracted via `log show` for each run's window:
       ```bash
       log show --start "<run start>" --end "<run end>" --info --debug --style compact \
         --predicate 'process == "coreaudiod" OR subsystem == "com.apple.bluetooth" OR subsystem == "com.razakhan.archie" OR process == "Dictate"' \
         > run_<N>_raw.log
       ```
