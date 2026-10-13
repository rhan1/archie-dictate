#!/bin/zsh
# live-rig.zsh (DictateKit v1.14) — the unattended headset crossover of tools/live-ab-protocol.md (§3 rows,
# §2 idle profile, §10 this rig). Live: drives the installed Archie host on Raza's GO; dry run: replays fixtures.
#
#   zsh tools/rig/live-rig.zsh [--dry-run] [--plan FILE] [--voice-log FILE] [--hal-log FILE] [--out DIR] [--help]
#
# Live (only with Raza's go: `touch ~/.claude/run-status/rig.GO`, the headset on the desk, nobody at the Mac):
#   per row — arm the back end (`launchctl setenv DICTATE_HEADSET_BACKEND`, DICTATE_RIG=1, DICTATE_RIG_DIR) with a guarded
#   relaunch of the SAME installed Archie bundle (version + binary hash + output volume read before and after, never
#   written); cold rows wait for `bt_after3s=a2dp … engine_allocated=false` + a released lease, then 30 s; warm rows go
#   at once; ⌥⌥ = a 0600 trigger file the host reads (never a synthetic keystroke); the passage through the BUILT-IN
#   speaker (`DictateBench rig-play`, its own engine bound to the built-in output, −12 dBFS peak; the default output and
#   the volume are never touched); ⌥⌥ again at clip end + 300 ms; the session-end line, the timeline, the HAL lines and
#   the pasted text (the host writes it to <rig dir>/out/<row>.txt, never to an app) fill <out>/table.md.
#   An unexpected state VOIDs the row and the rig moves on; a volume/bundle change or a host without the hook aborts.
#   On exit the variables are unset and, if the rig relaunched Archie, Archie is relaunched once more without them.
# Dry run: the same row routine on tools/fixtures/rig/live-ab-2026-10-13/ (the 10-13 15:05–15:25 log), a fake clock,
#   a fake host consuming the trigger file, `rig-play --fake` (asserts engine_opened=0) and the WAV hatch standing in
#   for the microphone. Every system command goes through side_effect (ledger only) and the commands that could
#   change anything are poisoned (exit 99). Last line `DRY-RUN PASS rows=11` reproduces live-protocol-results.md.
set -euo pipefail
zmodload zsh/datetime

REPO="${0:A:h:h:h}"
FIXTURE="$REPO/tools/fixtures/rig/live-ab-2026-10-13"
DRY_RUN=0 PLAN_FILE="" VOICE_LOG="" HAL_LOG="" OUT_DIR="$REPO/tools/rig/out"
ARCHIE_APP="$HOME/Applications/Archie.app"
ARCHIE_BIN="$ARCHIE_APP/Contents/MacOS/Archie"
GUARD_SCRIPT="${RIG_GUARD:-$HOME/.claude/handoffs/archie-v41-work/dictation-guard.py}"
GO_FILE="$HOME/.claude/run-status/rig.GO"
HEADSET_NAME="${RIG_HEADSET:-WH-1000XM6}"

while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --plan) PLAN_FILE="${2:A}"; shift 2 ;;
        --voice-log) VOICE_LOG="${2:A}"; shift 2 ;;
        --hal-log) HAL_LOG="${2:A}"; shift 2 ;;
        --out) OUT_DIR="${2:A}"; shift 2 ;;
        --help|-h) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -u2 -- "unknown option: $1"; exit 2 ;;
    esac
done
if (( DRY_RUN )); then
    : ${PLAN_FILE:=$FIXTURE/plan.tsv} ${VOICE_LOG:=$FIXTURE/voice.log} ${HAL_LOG:=$FIXTURE/hal.log}
else
    [[ -z "$VOICE_LOG$HAL_LOG" ]] || { print -u2 -- "--voice-log/--hal-log are dry-run only"; exit 2; }
    : ${PLAN_FILE:=$REPO/tools/rig/plan-abba.tsv}
    VOICE_LOG="$OUT_DIR/voice.stream.log" HAL_LOG="$OUT_DIR/hal.stream.log"
fi
mkdir -p "$OUT_DIR"
: > "$OUT_DIR/run.log"

log_step() { print -r -- "STEP $1 $2 $3" | tee -a "$OUT_DIR/run.log"; }
side_effect() {
    if (( DRY_RUN )); then print -r -- "DRY $*" >> "$OUT_DIR/run.log"; else "$@"; fi
}

# ---------- clock (dry run: the fixture's chord times; live: the wall clock), "YYYY-MM-DD HH:MM:SS.mmm" local ----------
FAKE_NOW_MS=0
now_ms() {
    if (( DRY_RUN )); then print -r -- $FAKE_NOW_MS
    else local r=$EPOCHREALTIME; print -r -- $(( ${r%.*} * 1000 + 10#${${r#*.}[1,3]} )); fi
}
ts_to_ms() { local s; strftime -s s -r '%Y-%m-%d %H:%M:%S' "${1%.*}"; print -r -- $(( s * 1000 + 10#${1##*.} )); }
ms_to_ts() { local s; strftime -s s '%Y-%m-%d %H:%M:%S' $(( $1 / 1000 )); printf '%s.%03d\n' "$s" $(( $1 % 1000 )); }
rig_sleep() { (( DRY_RUN )) && FAKE_NOW_MS=$(( FAKE_NOW_MS + ${1%.*} * 1000 )) || sleep "$1"; }

# ---------- log reading (identical in both modes: a compact-style log file; live = the growing stream file) ----------
# first line at/after <ts> whose text matches the ERE <re>
scan_first() { awk -v t="$2" -v re="$3" '($1 " " $2) >= t && $0 ~ re { print; exit }' "$1" 2>/dev/null || true; }
# wait_first <file> <after_ts> <re> <timeout_s>: live polls the stream every 250 ms; the dry run scans the complete file once
wait_first() {
    local hit deadline=$(( $(now_ms) + $4 * 1000 ))
    while true; do
        hit="$(scan_first "$1" "$2" "$3")"
        [[ -n "$hit" ]] && { print -r -- "$hit"; return 0; }
        (( DRY_RUN )) && return 1
        (( $(now_ms) >= deadline )) && return 1
        sleep 0.25
    done
}
line_ts() { print -r -- "${1[1,23]}"; }
# last line in [from, to] matching <re>
scan_last() { awk -v a="$2" -v b="$3" -v re="$4" '{ t = $1 " " $2 } t >= a && t <= b && $0 ~ re { hit = $0 } END { if (hit != "") print hit }' "$1" 2>/dev/null || true; }
get_field() { [[ "$2" =~ "(^|[[:space:]])$1=([^[:space:]]+)" ]] && print -r -- "${match[2]}" || print -r -- "${3:--}"; }
get_sub() { [[ "$2" =~ "(^|[[:space:]])$1=[^[:space:]]*$3:([^[:space:],]+)" ]] && print -r -- "${match[2]}" || print -r -- "-"; }

# ---------- dry-run safety ----------
if (( DRY_RUN )); then
    for poisoned in launchctl open pkill kill killall osascript afplay say; do
        eval "$poisoned() { print -u2 -- 'DRY-RUN VIOLATION $poisoned'; exit 99; }"
    done
    RIG_DIR="$(mktemp -d /tmp/dictate-v12-rigdry.XXXXXX)"
    trap 'rm -rf "$RIG_DIR"' EXIT          # replaced by cleanup() below
else
    RIG_DIR="$OUT_DIR/rig"
    mkdir -p "$RIG_DIR"; chmod 700 "$RIG_DIR"
    rm -f "$RIG_DIR/trigger"; rm -rf "$RIG_DIR/out"
fi

# ---------- host probes (read-only live; fixed in the dry run) ----------
probe_volume() { (( DRY_RUN )) && print -r -- "dry" || /usr/bin/osascript -e 'output volume of (get volume settings)'; }
probe_bundle() {
    if (( DRY_RUN )); then print -r -- "dry"; return; fi
    print -r -- "$(/usr/bin/defaults read "$ARCHIE_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null) $(/usr/bin/shasum -a 256 "$ARCHIE_BIN" | cut -c1-16)"
}
probe_pid() { (( DRY_RUN )) && print -r -- "fixture-pid" || pgrep -x Archie 2>/dev/null | head -1 || true; }
# The relaunch guard (archie-v41): CLEAR = no dictation/conversation in flight and 15 s of quiet. Waits ≤ 120 s.
guard_clear() {
    (( DRY_RUN )) && { side_effect guard; return 0; }
    local i
    for i in {1..24}; do
        /usr/bin/python3 -I "$GUARD_SCRIPT" >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

RELAUNCHED=0 ARMED=0 RL_INFO="" STREAM_PIDS=()
abort_run() { print -r -- "ABORT RUN $1" | tee -a "$OUT_DIR/run.log"; exit 4; }

# relaunch_host <label>: kill + open the SAME installed bundle; PRE==POST volume and bundle or abort.
relaunch_host() {
    local label="$1" pre_vol pre_bundle post_vol post_bundle pid launch_ts i
    guard_clear || abort_run "guard_busy"
    pre_vol="$(probe_volume)"; pre_bundle="$(probe_bundle)"; pid="$(probe_pid)"
    if [[ -n "$pid" ]]; then
        side_effect kill -TERM "$pid"
        if (( ! DRY_RUN )); then
            for i in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
            kill -0 "$pid" 2>/dev/null && abort_run "old_pid_alive"
        fi
    fi
    launch_ts="$(ms_to_ts $(now_ms))"
    side_effect open -a "$ARCHIE_APP"
    RELAUNCHED=1
    if [[ "$label" == rig ]]; then
        if (( DRY_RUN )); then side_effect expect "dictate: rig=on"
        else wait_first "$VOICE_LOG" "$launch_ts" 'dictate: rig=on' 30 >/dev/null || abort_run "rig_hook_missing"; fi
    else
        rig_sleep 10
    fi
    post_vol="$(probe_volume)"; post_bundle="$(probe_bundle)"
    [[ "$pre_vol" == "$post_vol" ]] || abort_run "volume_changed pre=$pre_vol post=$post_vol"
    [[ "$pre_bundle" == "$post_bundle" ]] || abort_run "bundle_changed"
    RL_INFO="volume=$pre_vol"
}

cleanup() {
    local rc=$?
    trap - EXIT
    if (( DRY_RUN )); then
        rm -rf "$RIG_DIR"
    else
        (( ${#STREAM_PIDS} )) && kill -TERM "${STREAM_PIDS[@]}" 2>/dev/null || true   # both log streams
        rm -f "$RIG_DIR/trigger" "$RIG_DIR/.trigger.tmp"
        if (( ARMED )); then     # only what this run set (a refused run changes nothing)
            launchctl unsetenv DICTATE_RIG 2>/dev/null || true
            launchctl unsetenv DICTATE_RIG_DIR 2>/dev/null || true
            launchctl unsetenv DICTATE_HEADSET_BACKEND 2>/dev/null || true
        fi
        if (( RELAUNCHED )); then
            # The host was launched with DICTATE_RIG=1: relaunch it without the variables (pastes go to apps again).
            if ( relaunch_host normal ) >> "$OUT_DIR/run.log" 2>&1; then
                print -r -- "HOST RESTORED (relaunched without DICTATE_RIG)" | tee -a "$OUT_DIR/run.log"
            else
                print -r -- "HOST NOT RESTORED — relaunch Archie by hand before dictating (it still writes pastes to $RIG_DIR/out)" | tee -a "$OUT_DIR/run.log"
            fi
        fi
    fi
    return $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------- DictateBench (rig-play, hatch) ----------
SW="${SW:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
"$SW" build --package-path "$REPO" --product DictateBench >/dev/null
BENCH="$("$SW" build --package-path "$REPO" --product DictateBench --show-bin-path)/DictateBench"

# The clip and its reference transcript are git-ignored; a worktree finds them in the main checkout.
voice_fixture() {
    local f="$REPO/tools/fixtures/voice/$1" common
    if [[ ! -f "$f" ]]; then
        common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        [[ -n "$common" && -f "${common:h}/tools/fixtures/voice/$1" ]] && f="${common:h}/tools/fixtures/voice/$1"
    fi
    print -r -- "$f"
}
WAV="$(voice_fixture raza-passage.wav)"
REF="$(voice_fixture raza-passage.ref.txt)"
(( DRY_RUN )) && REF="$FIXTURE/paste/reference.txt"

# ---------- plan ----------
typeset -a P_ROW P_ARM P_START P_NOTE
{
    IFS=$'\t' read -r h1 h2 h3 h4 || true
    [[ "$h1 $h2 $h3" == "row arm start" ]] || { print -u2 -- "PLAN ERROR header"; exit 2; }
    while IFS=$'\t' read -r r a s n; do
        [[ -z "$r" ]] && continue
        [[ "$a" == (engine|auhal) && "$s" == (cold|warm) ]] || { print -u2 -- "PLAN ERROR row $r"; exit 2; }
        [[ -n "${(M)P_ROW:#$r}" ]] && { print -u2 -- "PLAN ERROR duplicate $r"; exit 2; }
        [[ "$r" =~ '^[A-Za-z0-9_-]{1,16}$' ]] || { print -u2 -- "PLAN ERROR row name $r"; exit 2; }
        if [[ "$s" == warm ]] && (( ${#P_ARM} == 0 )) || [[ "$s" == warm && "${P_ARM[-1]}" != "$a" ]]; then
            print -u2 -- "PLAN ERROR warm row $r needs the previous row's arm"; exit 2
        fi
        P_ROW+=("$r") P_ARM+=("$a") P_START+=("$s") P_NOTE+=("${n:--}")
    done
} < "$PLAN_FILE"
(( ${#P_ROW} )) || { print -u2 -- "PLAN ERROR empty"; exit 2; }

# ---------- preconditions (all checked before the GO file is consumed) ----------
precondition_fail() { print -r -- "PRECONDITION FAIL $1" | tee -a "$OUT_DIR/run.log"; exit 3; }
[[ -f "$WAV" ]] || precondition_fail "wav $WAV"
if (( DRY_RUN )); then
    for f in "$VOICE_LOG" "$HAL_LOG" "$FIXTURE/clock.tsv" "$FIXTURE/expected.md"; do [[ -f "$f" ]] || precondition_fail "fixture $f"; done
    typeset -A CLOCK_AT CLOCK_SESSION
    while IFS=$'\t' read -r r t sid; do [[ "$r" == row ]] && continue; CLOCK_AT[$r]="$t"; CLOCK_SESSION[$r]="$sid"; done < "$FIXTURE/clock.tsv"
    log_step - preconditions fixture
else
    [[ -f "$GO_FILE" ]] || { print -r -- "NO GO: $GO_FILE is missing (Raza creates it)" | tee -a "$OUT_DIR/run.log"; exit 3; }
    system_profiler SPBluetoothDataType 2>/dev/null | awk '/Connected:/{c=1} /Not Connected:/{c=0} c' | grep -q "$HEADSET_NAME" \
        || precondition_fail "headset $HEADSET_NAME not connected"
    [[ "$(pgrep -x Archie | wc -l | tr -d ' ')" == 1 ]] || precondition_fail "host: not exactly one Archie"
    [[ "$(pgrep -x Dictate | wc -l | tr -d ' ')" == 0 ]] || precondition_fail "host: standalone Dictate running"
    [[ -f "$GUARD_SCRIPT" ]] || precondition_fail "guard script $GUARD_SCRIPT"
    /usr/bin/python3 -I "$GUARD_SCRIPT" >/dev/null 2>&1 || precondition_fail "dictation or conversation in flight"
    ! pmset -g assertions | grep -Eq 'Resources:.*audio-out|"Playing audio"' || precondition_fail "something is playing"
    mv "$GO_FILE" "$GO_FILE.used-$(date +%Y%m%d-%H%M%S)"
    log_step - preconditions "live go=consumed headset=$HEADSET_NAME ref=${REF:t}$([[ -f $REF ]] || print ' (missing: words=no-ref)')"
    /usr/bin/log stream --style compact --predicate 'subsystem == "com.razakhan.archie" AND category == "voice"' > "$VOICE_LOG" 2>/dev/null &
    STREAM_PIDS+=($!)
    # coreaudiod unfiltered (one process, one pid to stop); the HAL counts match their own lines.
    /usr/bin/log stream --style compact --predicate 'process == "coreaudiod"' > "$HAL_LOG" 2>/dev/null &
    STREAM_PIDS+=($!)
    sleep 2
fi

# ---------- trigger ----------
write_trigger() {
    ( umask 077; print -r -- "chord $1" > "$RIG_DIR/.trigger.tmp"; chmod 600 "$RIG_DIR/.trigger.tmp"; mv -f "$RIG_DIR/.trigger.tmp" "$RIG_DIR/trigger" )
}
# Dry run only: consume the trigger exactly as DictateKit's RigTriggerFile does; on the stop chord "paste" the fixture.
fake_host() {
    local f="$RIG_DIR/trigger" row="$1" phase="$2" content
    [[ -f "$f" && ! -L "$f" ]] || { rm -f "$f"; print -r -- type; return 1; }
    [[ "$(stat -f %u "$f")" == "$(id -u)" ]] || { rm -f "$f"; print -r -- owner; return 1; }
    [[ "$(stat -f %Lp "$f")" == 600 ]] || { rm -f "$f"; print -r -- mode; return 1; }
    (( $(stat -f %z "$f") <= 256 )) || { rm -f "$f"; print -r -- size; return 1; }
    content="$(<"$f")"; rm -f "$f"
    [[ "$content" == "chord $row" ]] || { print -r -- parse; return 1; }
    print -r -- "FAKEHOST chord row=$row" >> "$OUT_DIR/run.log"
    if [[ "$phase" == stop ]]; then
        mkdir -p "$RIG_DIR/out"; cp "$FIXTURE/paste/$row.txt" "$RIG_DIR/out/$row.txt"
    fi
    print -r -- ok
}
chord() {   # chord <row> <start|stop> → "ok" or the rejection
    write_trigger "$1"
    if (( DRY_RUN )); then fake_host "$1" "$2" || true; return; fi
    local i
    for i in {1..20}; do [[ -e "$RIG_DIR/trigger" ]] || { print -r -- ok; return; }; sleep 0.05; done
    rm -f "$RIG_DIR/trigger"; print -r -- "not_consumed"
}

compute_words() {   # vs the reference: line 1 = before the 2 s pause, line 2 = after it
    [[ -f "$1" ]] || { print -r -- "no-ref"; return; }
    [[ -f "$2" ]] || { print -r -- "no-paste"; return; }
    /usr/bin/python3 -I -c '
import re, sys
def norm(t): return re.sub(r"[^\w\s\x27]", "", t.lower()).split()
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
pre, post = norm(lines[0]) if lines else [], norm(" ".join(lines[1:]))
ref, hyp = pre + post, norm(open(sys.argv[2]).read())
M, N, M1 = len(ref), len(hyp), len(pre)
d = [[0] * (N + 1) for _ in range(M + 1)]
for i in range(M + 1): d[i][0] = i
for j in range(N + 1): d[0][j] = j
for i in range(1, M + 1):
    for j in range(1, N + 1):
        d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (ref[i-1] != hyp[j-1]))
i, j, S, D, I, post_ok = M, N, 0, 0, 0, 0
while i > 0 or j > 0:
    if i and j and ref[i-1] == hyp[j-1] and d[i][j] == d[i-1][j-1]:
        post_ok += i > M1; i -= 1; j -= 1
    elif i and j and d[i][j] == d[i-1][j-1] + 1: S += 1; i -= 1; j -= 1
    elif i and d[i][j] == d[i-1][j] + 1: D += 1; i -= 1
    else: I += 1; j -= 1
print(f"{M - S - D}/{M} misses={S + D + I} post_pause={post_ok}/{len(post) or M}")
' "$1" "$2"
}

# ---------- rows ----------
typeset -a TABLE STATUS COLS WORDS
prev_arm="" prev_end_ts="" prev_start_ts="" host_fresh=0

for idx in {1..${#P_ROW}}; do
    row="${P_ROW[idx]}" arm="${P_ARM[idx]}" start="${P_START[idx]}" note="${P_NOTE[idx]}"
    row_status=ok
    void() { [[ "$row_status" == ok ]] && row_status="VOID $1"; log_step "$row" void "$1"; }

    # 1 ARM — the first row and every arm change (never a warm row): setenv + guarded relaunch of the same bundle.
    if [[ "$start" == cold && "$arm" != "$prev_arm" ]]; then
        ARMED=1
        side_effect launchctl setenv DICTATE_HEADSET_BACKEND "$arm"
        side_effect launchctl setenv DICTATE_RIG 1
        side_effect launchctl setenv DICTATE_RIG_DIR "$RIG_DIR"
        relaunch_host rig
        log_step "$row" arm "$arm relaunched $RL_INFO"
        host_fresh=1
    fi

    # 2 IDLE — cold: A2DP back + engine released after the previous end, the previous lease released, then 30 s.
    if [[ "$start" == warm ]]; then
        log_step "$row" idle warm_immediate
    elif (( host_fresh )) || [[ -z "$prev_end_ts" ]]; then
        log_step "$row" idle "fresh_host"; rig_sleep 30
    else
        idle="$(wait_first "$VOICE_LOG" "$prev_end_ts" 'bt_after3s=a2dp bt_profile=a2dp engine_allocated=false' 180 || true)"
        lease="$(scan_last "$VOICE_LOG" "$prev_start_ts" "$(ms_to_ts $(( $(ts_to_ms "$prev_end_ts") + 5000 )))" 'lease_released=')"
        (( DRY_RUN )) && [[ -n "$idle" && "$(line_ts "$idle")" > "${CLOCK_AT[$row]}" ]] && idle=""
        if [[ -z "$idle" ]]; then
            (( DRY_RUN )) && log_step "$row" idle none || void idle_timeout
        else
            log_step "$row" idle "$(line_ts "$idle") lease=$(get_field state "$lease")"
            [[ "$(get_field state "$lease")" == quarantined ]] && void quarantined
            (( DRY_RUN )) || rig_sleep 30
        fi
    fi
    host_fresh=0

    # 3 CHORD (start) and 4 SESSION — the dry run's chord happens at the fixture's recorded time
    (( DRY_RUN )) && FAKE_NOW_MS=$(ts_to_ms "${CLOCK_AT[$row]}")
    chord_ms=$(now_ms); chord_ts="$(ms_to_ts $chord_ms)"
    got="$(chord "$row" start)"; log_step "$row" chord_start "$got"
    [[ "$got" == ok ]] || void "trigger_$got"
    start_line="$(wait_first "$VOICE_LOG" "$(ms_to_ts $(( chord_ms - 100 )))" 'session=[0-9a-f]+ event=start' 5 || true)"
    session=-; start_ts="$chord_ts"
    if [[ -n "$start_line" ]]; then
        session="$(get_field session "$start_line")"; start_ts="$(line_ts "$start_line")"
        (( DRY_RUN )) && [[ "$session" != "${CLOCK_SESSION[$row]}" ]] && void wrong_session
    else
        void no_session
    fi
    log_step "$row" session "$session"

    # 5 PLAY (the passage through the built-in speaker) — 6 HATCH in the dry run, standing in for the microphone
    if (( DRY_RUN )); then
        play="$("$BENCH" rig-play "$WAV" --level-dbfs -12 --fake)"
        [[ "$(get_field engine_opened "$play")" == 0 && "$(get_field result "$play")" == ok ]] \
            || { print -r -- "DRY-RUN FAIL engine_opened ($play)"; exit 1; }
        log_step "$row" play "engine_opened=0 result=ok"
        hatch="$("$BENCH" hatch "$WAV" "$arm" live_pause | head -1)"
        log_step "$row" hatch "carrier=$(get_field carrier "$hatch") mid_run_builtin_segments=$(get_field mid_run_builtin_segments "$hatch")"
        FAKE_NOW_MS=$(( FAKE_NOW_MS + $(get_field duration_ms "$play") ))
    elif [[ -n "$start_line" ]]; then
        play="$("$BENCH" rig-play "$WAV" --level-dbfs -12 || true)"
        log_step "$row" play "$play"
        [[ "$(get_field result "$play")" == ok ]] || void "play_$(get_field result "$play")"
    fi

    # 7 CHORD (stop) at clip end + 300 ms — 8 END
    end_line=""
    if [[ -n "$start_line" ]]; then
        rig_sleep 0.3
        got="$(chord "$row" stop)"; log_step "$row" chord_stop "$got"
        [[ "$got" == ok ]] || void "trigger_$got"
        end_line="$(wait_first "$VOICE_LOG" "$start_ts" "session=$session event=end" 45 || true)"
    fi
    [[ -n "$end_line" || -z "$start_line" ]] || void no_end
    end_ts="${end_line:+$(line_ts "$end_line")}"
    timeline="$( [[ -n "$end_ts" ]] && scan_last "$VOICE_LOG" "$start_ts" "$end_ts" 'dictate: timeline:' )"
    backend="$(get_field headset_backend "$end_line")"
    if [[ -n "$end_line" ]]; then
        [[ "$backend" == - ]] && void no_backend
        [[ "$backend" != - && "$backend" != "$arm" ]] && void "wrong_arm $backend"
        [[ "$start" == warm && -n "$prev_end_ts" ]] && (( $(ts_to_ms "$start_ts") - $(ts_to_ms "$prev_end_ts") > 2000 )) && void warm_late
        (( DRY_RUN )) || [[ "$(get_field rig "$end_line")" == 1 ]] || void not_rig
    fi
    outcome="$(get_field outcome "$end_line")" chars="$(get_field chars "$end_line" 0)"
    log_step "$row" end "outcome=$outcome chars=$chars"

    # 9 WORDS — the host's sink file for this row, copied next to the table
    rm -f "$OUT_DIR/$row.txt"
    if [[ -n "$end_line" ]]; then
        for i in {1..20}; do [[ -f "$RIG_DIR/out/$row.txt" ]] && break; (( DRY_RUN )) && break; sleep 0.25; done
        [[ -f "$RIG_DIR/out/$row.txt" ]] && cp "$RIG_DIR/out/$row.txt" "$OUT_DIR/$row.txt"
    fi
    words="$(compute_words "$REF" "$OUT_DIR/$row.txt")"
    log_step "$row" words "$words"

    # 10 HAL — [chord − 3 s, end + 3 s]
    hal_a="$(ms_to_ts $(( chord_ms - 3000 )))"
    hal_b="$(ms_to_ts $(( $(ts_to_ms "${end_ts:-$chord_ts}") + 3000 )))"
    # one pass (the live coreaudiod stream grows; a warm row must start within 2 s of this row's end)
    read -r starts stops escos route_d route_t < <(awk -v a="$hal_a" -v b="$hal_b" -v s="$start_ts" '
        { t = $1 " " $2 } t < a || t > b { next }
        /BTUnifiedAudioDevice: StartIO/ { n1++ } /BTUnifiedAudioDevice: StopIO/ { n2++ } /Dropping eSCO creation/ { n3++ }
        /Sco route is disabled/ && t >= s && r == "" { r = t }
        END { print n1 + 0, n2 + 0, n3 + 0, (r == "" ? "- -" : r) }' "$HAL_LOG" 2>/dev/null || print "0 0 0 - -")
    route=""; [[ "$route_d" != - ]] && route="$route_d $route_t"
    route_at=""; [[ -n "$route" ]] && route_at="+$(( $(ts_to_ms "$route") - $(ts_to_ms "$start_ts") ))"
    log_step "$row" hal "StartIO/StopIO=$starts/$stops eSCO=$escos route=${route_at:--}"

    # table row (cols 1–9 = live-protocol-results.md)
    row_col="$row"; [[ "$note" != - ]] && row_col="$row ($note)"
    start_col=cold
    if [[ "$start" == warm ]]; then
        gap=$(( $(ts_to_ms "$start_ts") - $(ts_to_ms "${prev_end_ts:-$start_ts}") ))
        start_col="warm (+$(LC_NUMERIC=C printf '%.1f' $(( gap / 1000.0 ))) s)"
    fi
    pasted="no ($outcome)"; [[ "$outcome" == ok && "$chars" == <-> ]] && (( chars > 0 )) && pasted="yes ${chars}ch"
    carrier="$(get_field carrier "$end_line")"; carrier="${${carrier//:/ }//,/, }"
    cols="$row_col | $arm | $start_col | $pasted | $(get_field first_buffer_ms "$timeline") | $carrier | $(get_field headset_carried_ms "$end_line") / $(get_field recording_ms "$end_line") | start:$( [[ "$end_line" =~ 'io_ops=start:([0-9]+)' ]] && print ${match[1]} || print - ) / $(get_field io_held "$end_line") | $(get_field mute_reapplied "$timeline")"
    ioops="-"; [[ "$end_line" =~ 'attempted:([0-9]+) completed:([0-9]+) failed:([0-9]+) framework:([0-9]+)' ]] && ioops="${(j:/:)match}"
    rig_col=-; [[ "$(get_field rig "$end_line")" == 1 ]] && rig_col=1
    esco_col=no; (( escos > 0 )) && esco_col="yes($escos)"
    TABLE+=("| $cols | $words | $session | $(get_field media "$timeline") | $(get_field fmt_epochs "$end_line") | $(get_sub io_callbacks "$end_line" headset) | $(get_sub frames "$end_line" headset) / $(get_sub zeros "$end_line" headset) | $(get_sub rms_dbfs "$end_line" headset) | $(get_field takeover_ms "$end_line") | $(get_field fallback_ms "$end_line") | $ioops | $(get_field io_obligations "$end_line") $(get_field io_obligation "$end_line") | $starts/$stops | $esco_col | ${route_at:--} | $rig_col | $row_status |")
    COLS+=("| $cols |") STATUS+=("$row_status") WORDS+=("$words")

    prev_arm="$arm"
    [[ -n "$end_ts" ]] && { prev_end_ts="$end_ts"; prev_start_ts="$start_ts"; }
    (( DRY_RUN )) || { [[ -n "$end_line" ]] || rig_sleep 5; }
done

# ---------- table ----------
ok=${#${(M)STATUS:#ok}}
voids=(); for i in {1..${#P_ROW}}; do [[ "${STATUS[i]}" == ok ]] || voids+=("${P_ROW[i]}"); done
{
    print -r -- "# Rig table — $( (( DRY_RUN )) && print dry-run || print live ) $(strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS) plan=${PLAN_FILE#$REPO/}"
    print
    print -r -- "| Row | Arm | Start | Pasted | first_buffer | carrier (ms) | headset_carried / rec | io_ops / held | mute_reapplied | words | session | media | fmt_epochs | io_callbacks h | frames h / zeros h | rms h | takeover_ms | fallback_ms | io_ops att/comp/fail/fw | obligation | HAL StartIO/StopIO | eSCO dropped? | route disabled @ | rig | status |"
    print -r -- "|$(printf '%.0s---|' {1..25})"
    print -l -r -- "${TABLE[@]}"
    print
    print -r -- "rows=$ok/${#P_ROW} void=${(j:,:)voids:-none}"
} > "$OUT_DIR/table.md"

if (( ! DRY_RUN )); then
    print -r -- "RIG DONE rows=$ok/${#P_ROW} void=${(j:,:)voids:-none}" | tee -a "$OUT_DIR/run.log"
    exit 0
fi

# ---------- dry run: today's literals ----------
typeset -A EXPECTED_WORDS=(
    1 "25/26 misses=1 post_pause=14/14"   2 "25/26 misses=1 post_pause=14/14"   3 "26/26 misses=0 post_pause=14/14"
    4 "26/26 misses=0 post_pause=14/14"   A1 "25/26 misses=1 post_pause=13/14"  A2 "26/26 misses=0 post_pause=14/14"
    A3 "25/26 misses=1 post_pause=13/14"  A4 "25/26 misses=1 post_pause=13/14"  W1 "24/26 misses=2 post_pause=14/14"
    E4 "26/26 misses=0 post_pause=14/14"  W2 "26/26 misses=0 post_pause=14/14"
)
mismatch=()
expected=("${(@f)$(<"$FIXTURE/expected.md")}")
(( ${#expected} == ${#P_ROW} )) || mismatch+=("rowcount")
for i in {1..${#P_ROW}}; do
    r="${P_ROW[i]}"
    if [[ "${COLS[i]}" != "${expected[i]:-}" ]]; then
        mismatch+=("$r")
        print -u2 -- "DIFF $r actual:   ${COLS[i]}"; print -u2 -- "DIFF $r expected: ${expected[i]:-}"
    fi
    [[ "${WORDS[i]}" == "${EXPECTED_WORDS[$r]:-}" ]] || { mismatch+=("$r(words)"); print -u2 -- "DIFF $r words: ${WORDS[i]}"; }
done
if (( ${#voids} || ${#mismatch} )); then
    print -r -- "DRY-RUN FAIL rows=$ok/${#P_ROW} void=${(j:,:)voids:-none} mismatch=${(j:,:)mismatch:-none}"
    exit 1
fi
print -r -- "DRY-RUN PASS rows=${#P_ROW}"
