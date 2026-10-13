# Live A/B Protocol — headset backend (DictateKit v1.12; second crossover on v1.13, §9; unattended rig v1.14, §10)

The GPT-6 review's §B deciding experiment, step by step: one operator-supervised, instrumented
crossover between the two headset clients DictateKit v1.12 can run (v1.13 for the second crossover, §9), on the same MacBook and the
same Sony WH-1000XM6, in the same session.

- **Arm E — `engine`** (default, v1.0–v1.11): the AVAudioEngine input node, which follows the
  default device (and its `CADefaultDeviceAggregate`).
- **Arm A — `auhal`** (v1.12 L3): `HeadsetCaptureUnit`, an explicit-device, input-only AUHAL bound
  to the headset's UID (output element disabled, no aggregate, hardware rate taken as-is,
  conversion off the IO thread).

Everything else is identical in both arms: built-in continuity (`BuiltinCaptureUnit`), the bridge,
the health clock, the recovery episode and obligation policy, the capture lease, and the
instrumentation on the session line.

> [!IMPORTANT]
> Run by **Raza** (operator, speaks) with **Fable** (observer, captures logs and fills the table).
> No agent runs this protocol, and nothing here was run on hardware before it. The headset
> behaviour of either arm is **unproven** until this protocol has been executed.
> One session locates the failing **layer**. It cannot estimate a failure **rate**, so never
> report a handful of passes as reliability.

---

## Results so far

2026-10-13 15:05–15:25, Archie 42.0 on DictateKit v1.12 (1514a63), Sony WH-1000XM6: eleven runs — table in `~/.claude/handoffs/archie-v35-work/live-protocol-results.md` (section "2026-10-13 15:05–15:25"), raw log `archie-v35-work/raw/live-ab-2026-10-13-1504-1526.log`.

- **Both arms carried on the headset**: exact zeros were received from the Sony on both arms (`zeros=…headset:` 49811/389712 auhal A1, 53684/357552 engine row 1, 19704–51926 on other engine runs) across delivery sizes of 480 frames (`io_callbacks=headset:812` auhal) vs 2400 frames (`149` engine).
- **AUHAL dip at the two-second pause**: A1–A4 each showed a 0.2–0.7 s built-in segment at the passage's pause (`bridge_switchback=1` triggered after > 0.5 s of headset digital silence alone), then `bridge_switch=headset reason=recovered` 150 ms+ into the next word ("We need" → "When you need"); engine dipped once at the pause (row 4 `builtin:7135-8537`).
- **Engine warm HFP waited 2431 ms**: E4 and W2 waited `carrier=builtin:0-2431` identically to the millisecond via `hands_off path=configuration engine_running=1` (+116/+113 ms) → 0.7 s zeros → `headset_restart=1 path=restart idle=1 waited_ms=300` → `obligation path=configuration engine_running=0` (+128 ms) → `settled path=restart result=no_frames` (+1.0 s) → `reattach path=obligation reason=engine_stopped` → signal 240 ms later → `bridge_switch=headset reason=recovered`.
- **Handover misses**: both engine-arm misses sit on source switches (run 1 "so for" → "if you're a fan of" across `builtin:0-910,headset:910-1924,builtin:1924-3353`; run 2 "draft" → "drop" at the 2318 ms takeover). A timestamp splice repeats the headset's transit lag at a takeover and drops it at a switchback (hatch-modeled; the live lag is unmeasured — v1.13 logs it as `splice_align_ms=`).
- **A4 tail**: A4 delivered frames until 7 ms before the stop (`recording_ms=15881 capture_intervals=0-15874`); `AudioRecorder.stop()` keeps everything delivered. The missing final "Thanks" is either the chord landing on the word or audio still in Bluetooth transit at the chord — the counts cannot tell which (§9 records it).

---

## 0. Hard rules (both arms)

1. **Never both headset clients at once.** Exactly one host process with exactly one arm. Before
   every run, `pgrep -lf 'Dictate|Archie'` lists exactly the one host you intend to use.
2. **No device or volume changes.** Do not change the default input or output, the system volume, or
   the headset's controls. Mute/restore by DictateKit is observed, never forced.
3. **Same idle profile before every cold run** (§2). Never start a run while the headset is still
   on HFP from the previous one.
4. **Do not wait for HFP before opening the client that starts HFP.** Both arms open their
   client on the first ⌥ tap, as in production.
5. **Esc cancels.** If anything unexpected happens (stuck pill, audible glitch, wrong route),
   press Esc, stop the run, note it in the table and continue with the next run. Do not improvise
   a fix mid-protocol.
6. **No transcripts or audio leave the Mac.** The table holds counts, ms and marker
   present/absent; it never holds pasted text. Clips under `tools/fixtures/voice/` stay git-ignored.

---

## 1. Preconditions (record once)

```bash
cd ~/Projects/dictate && git rev-parse --short HEAD && git describe --tags   # expect v1.12
sw_vers
system_profiler SPBluetoothDataType 2>/dev/null | grep -A3 'WH-1000XM6'      # connected, firmware
```

- Host: the standalone `Dictate.app` is the reference host (Archie pins DictateKit separately;
  if Archie is used, record its version and its `Package.resolved` DictateKit revision).
- Note the background-media condition you will hold constant (recommended: **no media playing**
  for every run; if you choose a video playing to the headset, keep it playing in every run of
  both arms).
- Note the default output (expected: the headset) and its prior mute state, by observation only.

### Selecting the arm

The arm is read once per process from `DICTATE_HEADSET_BACKEND` (`engine` when unset).
A host can also pass it explicitly: `AudioRecorder(headsetBackend: .auhal)`.

- **Standalone Dictate, from Terminal** (reference):
  ```bash
  pkill -x Dictate; sleep 2
  DICTATE_HEADSET_BACKEND=engine "$HOME/Applications/Dictate.app/Contents/MacOS/Dictate" 2>>"$HOME/Library/Logs/Dictate/dictate.stderr.log" &
  # arm A: the same with DICTATE_HEADSET_BACKEND=auhal
  ```
  (Use the installed app path; if the LaunchAgent keeps Dictate alive, unload it for the session
  with `launchctl bootout gui/$(id -u)/<label>` and bootstrap it again in §6.)
- **Archie-hosted**: `launchctl setenv DICTATE_HEADSET_BACKEND auhal` before launching Archie,
  and `launchctl unsetenv DICTATE_HEADSET_BACKEND` afterwards (§6).

Every session-end line names its arm: `headset_backend=engine|auhal`. A run whose line shows the
wrong arm is void.

---

## 2. Idle profile (before EVERY cold run)

1. The previous run has ended (pill gone, text pasted or cancelled).
2. Wait until DictateKit reports the headset back on A2DP **and** the engine released:
   ```text
   bt_after3s=a2dp bt_profile=a2dp engine_allocated=false
   ```
   then wait a further **30 s** with no audio client active (no calls, no dictation, the same
   media condition as §1).
3. The previous lease is released: the line `lease_released=N state=released` for the previous
   session is present. (`state=quarantined` = stop and record it: a teardown never completed.)

Warm-HFP runs (§3, W rows) skip step 2's A2DP wait: they start within 2 s of the previous run's
end, while the headset is still on HFP.

---

## 3. Run order (crossover)

Cold-A2DP runs alternate arms in an ABBA pattern so time-of-session effects cancel. W rows are
the warm-HFP control (review: R4 carried on warm HFP).

| # | Arm | Start state | Gesture |
|---|-----|-------------|---------|
| 1 | E | cold A2DP | ⌥⌥ dictation, passage P |
| 2 | A | cold A2DP | ⌥⌥ dictation, passage P |
| 3 | A | cold A2DP | ⌥⌥ dictation, passage P |
| 4 | E | cold A2DP | ⌥⌥ dictation, passage P |
| W1 | (arm of #4) | warm HFP (≤ 2 s after #4) | ⌥⌥ dictation, passage P |
| 5 | E | cold A2DP | ⌥⌥ dictation, passage P |
| 6 | A | cold A2DP | ⌥⌥ dictation, passage P |
| W2 | (arm of #6) | warm HFP (≤ 2 s after #6) | ⌥⌥ dictation, passage P |

Switching arms means quitting the host, confirming `pgrep` shows nothing, relaunching with the
other value, and then going through the full §2 idle profile. If time allows, repeat rows 1–6
once more and report every run, failures included.

---

## 4. Passage P (≈ 12 s)

Speak at normal volume and distance, starting **immediately** after the second ⌥ tap:

> "**Banana** first. Then the number is forty-seven. *[pause two full seconds]* Finally, the
> violet giraffe crossed Lisbon at noon."

Markers (present/absent only, never the text):

- **opening** — `Banana` (catches a lost first word during route acquisition)
- **number** — `47` or `forty-seven`
- **pause** — the 2 s pause does not end the dictation (`mic_dead`) and creates no duplicate
- **final** — `violet giraffe crossed Lisbon at noon` complete (a unique final sentence: catches
  a lost tail and invented trailing words)

---

## 5. What to capture per run

### 5.1 DictateKit lines (counts only)

Standalone: `~/Library/Logs/Dictate/dictate.stderr.log`. Archie-hosted: the unified log
(`subsystem == "com.razakhan.archie" AND category == "voice"`, lines containing ` dk `). Call
`/usr/bin/log` by full path (in zsh, bare `log` is a builtin), and use whole seconds for `--start`.

From the session-end line (`session=… event=end …`), copy these fields:

| Field | Meaning |
|-------|---------|
| `headset_backend=` | the arm (must match the row) |
| `route_uid=` | the headset UID the session resolved |
| `fmt_epochs=` | every headset format seen, `gen:rateHz/ch@ms` from the recording boundary (negative = prewarm) |
| `io_callbacks=builtin:N,headset:N` | IO callbacks per source that delivered converted frames (tap blocks / AUHAL slots), counted identically in both arms |
| `frames=` `zeros=` `rms_dbfs=` | 24 kHz frames delivered per source, digital zeros, RMS |
| `takeover_ms=` `fallback_ms=` | headset takeovers and built-in fallbacks/switchbacks (ms) |
| `carrier=` `headset_carried_ms=` | which source carried the dictation (intervals) |
| `carrier_frames=` | the exact per-frame runs, gaps visible |
| `io_ops=… attempted:N completed:N failed:N framework:N` | our engine operations vs the OS's own stops |
| `io_obligations=O/D io_obligation=… reattaches=N` | stopped-client obligations opened/discharged; `open:` at the end = still owed IO |
| `lease=… lease_wait_ms=` | the lease; with the following `lease_released=… release_ms=` |

Also note any of `bt_recovery=…`, `headset_signal_start=1`, `headset_format_changed=`,
`headset_callbacks_stopped=1`, `headset_device_lost=1` and `bridge_src=builtin_fallback`, with their
timestamps.

### 5.2 HAL / Bluetooth events (monotonic clock)

For each run's window (start = second ⌥ tap − 3 s, end = paste + 3 s):

```bash
/usr/bin/log show --start "YYYY-MM-DD HH:MM:SS" --end "YYYY-MM-DD HH:MM:SS" --info --debug --style compact \
  --predicate 'process == "coreaudiod" OR subsystem == "com.apple.bluetooth" OR process == "Dictate" OR subsystem == "com.razakhan.archie"' \
  > ~/.claude/handoffs/dictate-ab-work/run-<#>-<arm>.log
```

Count IO starts and stops with `BTUnifiedAudioDevice: StartIO` / `StopIO` (one line each). Do
**not** count `BluetoothHALPlugIn_StartIO` (printed 4× per start) or `StopIO` (2× per stop). Note
the times of: SCO/eSCO link connect, `Dropping eSCO creation`, `Sco route is disabled`, every
IO start and stop. In arm E, the client context `CADefaultDeviceAggregate-<pid>-N` appears; in
arm A it must not (its client is the headset device itself). Seeing it in arm A voids the run.

---

## 6. Results table (one row per run)

| # | arm | session | start | fmt_epochs | io_callbacks h | frames h / zeros h | rms h | takeover_ms | fallback_ms | carrier | headset_carried_ms | carrier_frames gaps | io_ops (att/comp/fail/fw) | obligation | HAL StartIO/StopIO | eSCO dropped? | route disabled @ | opening | number | pause ok | final | notes |
|---|-----|---------|-------|------------|----------------|--------------------|-------|-------------|-------------|---------|--------------------|---------------------|---------------------------|------------|--------------------|---------------|------------------|---------|--------|----------|-------|-------|

---

## 7. Reading the result (review §B)

Compare the cold-A2DP rows of the two arms, layer by layer:

1. **AUHAL keeps headset IO and usable headset PCM through the A2DP→HFP transition while the
   engine loses it.** Arm A shows `takeover_ms` set, `carrier` ending on `headset`, high
   `headset_carried_ms`, few headset `zeros`, no `framework` stops, StartIO/StopIO about 1/1. Arm E
   shows `framework` stops, obligations, eSCO dropped and `builtin_fallback`. **Verdict:** the
   backend/aggregate hypothesis wins. Raza then decides separately whether to make `auhal` the
   default (a later version; not part of this protocol).
2. **Both arms lose IO at the same point** (StopIO + `Sco route is disabled` at similar offsets,
   with headset zeros or no headset frames in both). **Verdict:** the Swift wrapper is not the
   cause; the route/HFP lifetime is. Changing the client is insufficient.
3. **Raw headset PCM is healthy but not selected.** Headset `frames` and `rms_dbfs` look like
   speech and headset `zeros` are low, yet `carrier` stays built-in or `fallback_ms` fires.
   **Verdict:** arbitration/thresholds/conversion is the failing layer, not capture.
4. **Warm rows (W1/W2) carry in both arms and cold rows fail in both:** profile acquisition is the
   problem, not playback or the microphone (review: R4 carried on warm HFP).

Whatever the verdict, also report:
- the content markers (opening/number/pause/final) per run;
- any `io_obligation=open:` at a session end (a stopped client still owed IO);
- any `lease_released=… state=quarantined`;
- every void or cancelled run and its reason.

---

## 8. Close-out

```bash
launchctl unsetenv DICTATE_HEADSET_BACKEND 2>/dev/null; launchctl getenv DICTATE_HEADSET_BACKEND   # empty
pkill -x Dictate; sleep 2   # then relaunch normally / bootstrap the LaunchAgent again
```

- The default arm is `engine` again (the next session line shows `headset_backend=engine`).
- The prior mute state is restored (`media=…>restored(verified)` on the last line). Observe it, never force it.
- The headset returns to A2DP (`bt_after3s=a2dp`).
- The table and the raw logs under `~/.claude/handoffs/dictate-ab-work/` are matched to session ids and
  to the build hash from §1. Nothing from this protocol is committed to the repository.

---

## 9. Second crossover after v1.13

Run the same sequence and protocol steps (§§ 0–6) as the first crossover, now executed on DictateKit v1.13 (tag `v1.13` of `https://github.com/rhan1/archie-dictate`; the host's pin is the revision in the `FINAL:` line of `~/.claude/handoffs/dictate-v11.report.md` — check `Package.resolved` against it before the first run).

### What to record per run (in addition to §5)

For each run, capture and record the following metrics in the session notes:
1. **Bridge switches and peaks**: every `bridge_switch=<to> reason=<why> headset_peak=<f> builtin_peak=<f>` line logged during the session.
2. **Splice alignment**: `splice_align_ms=` and `corr=` at the first takeover decision.
3. **Warm engine recovery**: on warm starts (arm E, W rows), record whether `bt_recovery=immediate … reason=warm_format_change` appears and the first headset millisecond in `carrier=` (expected `takeover_ms` ≤ 300 ms).
4. **Pause carrier continuity**: verify whether a mid-run `builtin:` segment appears at the passage's two-second pause. Expected: none, unless the switch log explicitly shows `reason=witness` with `builtin_peak` ≥ 0.01.
5. **Finishing chord landing**: the operator's note recording whether the finishing chord (second ⌥) landed on the last word ("noon") or after it (used to decide the L4 v1.14 candidate for Bluetooth transit tail drain).
6. **Bluetooth proof gate**: run `tools/bt-proof.sh --log-window …` and record `SWITCH`, `PEAKS_SEEN=`, and `VERDICT pause=PASS|FAIL|NA` (must report `PASS` or `NA`, with no `BT-PROOF: FAIL pause_switch@`).

### Success criteria checklist

- [ ] **No false switchback at pause**: zero mid-run `builtin:` carrier segments during the 2 s pause on both arms, with `bridge_switchback=0` (or witnessed switch only if `builtin_peak` ≥ 0.01).
- [ ] **Immediate warm HFP takeover**: warm engine arm takes over with `takeover_ms` ≤ 300 ms (via `bt_recovery=immediate … reason=warm_format_change`), matching AUHAL warm performance.
- [ ] **Seamless content splice**: `splice_align_ms` cross-correlation reported (`corr` ≥ 0.60) with no clipped words or duplicate syllables at handover ("Banana first", "Then the number").
- [ ] **Tail speech preserved**: final sentence "crossed Lisbon at noon" fully delivered when chord lands after the word.
- [ ] **Clean bt-proof gate**: `tools/bt-proof.sh` reports `VERDICT pause=PASS` (or `NA`) across all runs with `PEAKS_SEEN=` confirmed.


---

## 10. Unattended rig (v1.14)

`tools/rig/live-rig.zsh` runs §3's crossover (ABBA + W rows, `tools/rig/plan-abba.tsv`) with §2's idle profile
before every cold row, and fills `tools/rig/out/table.md` — without an operator at the desk. It plays the recorded
passage (`tools/fixtures/voice/raza-passage.wav`) through the MacBook's **built-in speaker** into the headset lying on the
desk, and performs ⌥⌥ through a test-only trigger file, never a synthetic keystroke.

**What Raza does:** put the headset on the desk next to the MacBook (on, connected, nothing playing), step away, and
create the GO file — `touch ~/.claude/run-status/rig.GO` — then start the rig (`zsh tools/rig/live-rig.zsh`) or ask the
architect to. **What Raza never does during the run:** nothing — no typing, no media, no calls; the rig stops itself.

### Preconditions (printed and checked; any failure stops before the first row)

1. The GO file `~/.claude/run-status/rig.GO` exists (Raza creates it; the rig consumes it, so every run needs a new go).
2. The headset is connected (`system_profiler SPBluetoothDataType` lists it under Connected).
3. Archie is the host: exactly one `Archie` process, no standalone `Dictate`; its DictateKit pin is v1.14 or later
   **and** the Archie-side `enableRig` line is in (else the relaunch never logs `rig=on` and the rig aborts).
4. No dictation or conversation in flight (the relaunch guard prints `CLEAR`).
5. Nothing playing (`pmset -g assertions`: no `audio-out` resource, no "Playing audio").

### What it does per row

Arm: `launchctl setenv DICTATE_HEADSET_BACKEND <arm>` plus `DICTATE_RIG=1` and `DICTATE_RIG_DIR`, then a guarded relaunch
of the **same** installed Archie bundle (kill + open; version and binary hash checked before and after; the output volume
is read before and after, never written — a difference aborts the whole run). Cold rows wait for
`bt_after3s=a2dp bt_profile=a2dp engine_allocated=false` and a released lease, then 30 s; warm rows start within 2 s of the
previous row's end. Then: chord → `session=… event=start` → the passage through the built-in speaker (its own engine bound
to the built-in output by UID, peak −12 dBFS; the default output device and the system volume are never changed) →
chord at clip end + 300 ms → `session=… event=end` (which must carry `rig=1`). The paste goes to
`tools/rig/out/<row>.txt` (git-ignored), never to the frontmost app; the table scores it against
`tools/fixtures/voice/raza-passage.ref.txt` (git-ignored; without it the words column reads `no-ref`).

Abort rules: an unexpected state VOIDs the row with its reason and the rig moves to the next row; it never improvises.
A volume or bundle change, or a host without the rig hook, stops the whole run. On exit (normal, error or Ctrl-C) the
rig removes the trigger file and unsets `DICTATE_RIG`, `DICTATE_RIG_DIR` and `DICTATE_HEADSET_BACKEND`.

### The hooks are inert by default

The host reads nothing from the trigger directory and pastes normally unless it was **launched** with `DICTATE_RIG=1`
and an absolute `DICTATE_RIG_DIR` (`RigInertTests`: RED when the gate ignores the variable). After the rig, relaunch
Archie normally (§8) so the next launch has neither variable.

### Dry run (offline; no audio device, no host, no system change)

```bash
zsh tools/rig/live-rig.zsh --dry-run | tail -1        # DRY-RUN PASS rows=11
```

Replays the 10-13 15:05–15:25 crossover (`tools/fixtures/rig/live-ab-2026-10-13/`: the Archie `dk` lines and HAL lines
of `archie-v35-work/raw/live-ab-2026-10-13-1504-1526.log`) through every step: the trigger file is consumed by a fake
host, the speaker is `rig-play --fake` (asserts `engine_opened=0`), the WAV hatch stands in for the microphone, and the
table must reproduce the eleven rows of `live-protocol-results.md` (§2026-10-13) literally. The word column uses
synthetic stand-in pastes (no transcript is committed). RED: `--voice-log tools/fixtures/rig/red-missing-backend.voice.log`
(row A2's end line without `headset_backend=`) → A2 `VOID no_backend`, `DRY-RUN FAIL`.
