# Live A/B Protocol — headset backend (DictateKit v1.12)

The GPT-6 review's §B deciding experiment, step by step: one operator-supervised, instrumented
crossover between the two headset clients DictateKit v1.12 can run, on the same MacBook and the
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
