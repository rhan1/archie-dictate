#!/bin/bash
set -u

# Analysis function callable by tests or main flow
analyse() {
    local stderr_file="${1:-}"
    local probe_file="${2:-}"

    local n_timeline=0
    local n_after=0
    local n_a2dp=0
    local n_foreign=0
    local n_abandon=0

    if [ -n "$stderr_file" ] && [ -f "$stderr_file" ]; then
        n_timeline=$(grep -c "timeline:" "$stderr_file" 2>/dev/null || true)
        n_after=$(grep -c "bt_after3s=" "$stderr_file" 2>/dev/null || true)
        n_a2dp=$(grep "bt_after3s=a2dp" "$stderr_file" 2>/dev/null | grep -c "engine_allocated=false" || true)
        n_foreign=$(grep -c "bt_hfp_foreign=1" "$stderr_file" 2>/dev/null || true)
        n_abandon=$(grep -c "bridge_abandoned=1" "$stderr_file" 2>/dev/null || true)
    fi

    n_timeline=${n_timeline:-0}
    n_after=${n_after:-0}
    n_a2dp=${n_a2dp:-0}
    n_foreign=${n_foreign:-0}
    n_abandon=${n_abandon:-0}

    local last_rate=""
    local last_in=""
    local hfp_samples=0

    if [ -n "$probe_file" ] && [ -f "$probe_file" ]; then
        local last_line
        last_line=$(grep -v '^[[:space:]]*$' "$probe_file" 2>/dev/null | tail -n 1 || true)
        if [[ "$last_line" =~ out_rate=([0-9]+) ]]; then
            last_rate="${BASH_REMATCH[1]}"
        fi
        if [[ "$last_line" =~ in_running=([0-9]+) ]]; then
            last_in="${BASH_REMATCH[1]}"
        fi
        hfp_samples=$(grep -c "out_rate=16000" "$probe_file" 2>/dev/null || true)
    fi

    hfp_samples=${hfp_samples:-0}

    echo "Summary:"
    echo "  N_TIMELINE: $n_timeline"
    echo "  N_AFTER: $n_after"
    echo "  N_A2DP: $n_a2dp"
    echo "  N_FOREIGN: $n_foreign"
    echo "  N_ABANDON: $n_abandon"
    echo "  LAST_RATE: ${last_rate:-none}"
    echo "  LAST_IN: ${last_in:-none}"
    echo "  HFP_SAMPLES: $hfp_samples"

    if [ -n "$stderr_file" ] && [ -f "$stderr_file" ]; then
        grep -E "bt_after3s|bt_hfp_foreign|bridge_abandoned|tap2_to_first_kept_buffer_ms" "$stderr_file" 2>/dev/null | awk '
        {
            if ($0 ~ /timeline:/) {
                match($0, /.*timeline:/)
                prefix = substr($0, RSTART, RLENGTH)
                rest = substr($0, RSTART + RLENGTH)
                n = split(rest, words, " ")
                kept = ""
                for (i = 1; i <= n; i++) {
                    w = words[i]
                    if (w ~ /^(bt_start=|bridge_ms=|bridge_src=|tap2_to_first_kept_buffer_ms=|first_buffer_ms=)/) {
                        kept = (kept == "" ? w : kept " " w)
                    }
                }
                if (kept != "") {
                    print prefix " " kept
                } else {
                    print prefix
                }
            } else {
                print $0
            }
        }
        ' || true
    fi

    if [ "$n_foreign" -gt 0 ]; then
        echo "another app held the headset microphone while Dictate was idle (bt_hfp_foreign=1)"
    fi

    local reasons=()
    if [ "$n_timeline" -lt 2 ]; then
        reasons+=("N_TIMELINE < 2 ($n_timeline)")
    fi
    if [ "$n_a2dp" -lt 2 ]; then
        reasons+=("N_A2DP < 2 ($n_a2dp)")
    fi
    if [ "$n_a2dp" -ne "$n_after" ]; then
        reasons+=("N_A2DP != N_AFTER ($n_a2dp != $n_after)")
    fi
    if [ "$n_abandon" -ne 0 ]; then
        reasons+=("N_ABANDON != 0 ($n_abandon)")
    fi
    if [ "$last_rate" != "44100" ]; then
        reasons+=("LAST_RATE != 44100 (${last_rate:-missing})")
    fi
    if [ "$last_in" != "0" ]; then
        reasons+=("LAST_IN != 0 (${last_in:-missing})")
    fi

    if [ ${#reasons[@]} -eq 0 ]; then
        echo "BT-PROOF: PASS"
        return 0
    else
        local reason_str=""
        for r in "${reasons[@]}"; do
            if [ -z "$reason_str" ]; then
                reason_str="$r"
            else
                reason_str="$reason_str, $r"
            fi
        done
        echo "BT-PROOF: FAIL $reason_str"
        return 1
    fi
}

main() {
    local REPO
    REPO="$(cd "$(dirname "$0")/.." && pwd)"
    # Same pinned toolchain as make-app.sh / bench.sh; plain `swift` only if it is missing.
    SW="$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift"
    [[ -x "$SW" ]] || SW=swift

    local LOG="$HOME/Library/Logs/Dictate/dictate.stderr.log"
    local START_LINES=0
    if [ -f "$LOG" ]; then
        START_LINES=$(wc -l < "$LOG" | tr -d '[:space:]')
    fi
    START_LINES=${START_LINES:-0}

    local PROBE_LOG="/tmp/bt-proof.probe.log"
    local PID=""
    "$SW" "$REPO/tools/probes/bt-probe.swift" 75 > "$PROBE_LOG" 2>/dev/null &
    PID=$!
    trap 'kill $PID 2>/dev/null' EXIT

    echo "Bluetooth proof (≈ 2 min). Headset on, music playing."
    echo "1) Dictate one sentence: ⌥⌥ … speak … ⌥"
    echo "2) Wait for the countdown, then dictate a second sentence."
    echo "Press Return to begin."
    read -r _

    echo "Dictation 1 now (you have 20 s)…"
    sleep 20

    echo "Wait…"
    echo "15 s…"
    sleep 5
    echo "10 s…"
    sleep 5
    echo "5 s…"
    sleep 5

    echo "Dictation 2 now (you have 20 s)…"
    sleep 20

    echo "Settling 10 s…"
    sleep 10

    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true

    local STDERR_SECTION="/tmp/bt-proof.section.log"
    if [ -f "$LOG" ]; then
        tail -n +"$((START_LINES + 1))" "$LOG" > "$STDERR_SECTION"
    else
        : > "$STDERR_SECTION"
    fi

    analyse "$STDERR_SECTION" "$PROBE_LOG"
}

esco_usage() {
    echo "Usage: $0 [--log <minutes> | --log-window '<start>' '<end>' | --from-file <coreaudio.log> [<notes.log>] | analyse <stderr> <probe>]" >&2
    exit 2
}

esco_analyse() {
    local ca_file="$1"
    local notes_file="${2:-/dev/null}"

    /usr/bin/awk '
    function days_from_civil(y, m, d,   era, yoe, m_adj, doy, doe) {
        if (m <= 2) {
            y = y - 1
            m_adj = m + 9
        } else {
            m_adj = m - 3
        }
        era = int(y / 400)
        yoe = y - era * 400
        doy = int((153 * m_adj + 2) / 5) + d - 1
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
        return era * 146097 + doe
    }

    function parse_time(d_str, t_str,   d_parts, t_parts, s_parts, y, m, d, h, min, s, ms_str, ms) {
        if (split(d_str, d_parts, "-") != 3) return -1
        y = d_parts[1] + 0
        m = d_parts[2] + 0
        d = d_parts[3] + 0
        if (split(t_str, t_parts, ":") != 3) return -1
        h = t_parts[1] + 0
        min = t_parts[2] + 0
        if (split(t_parts[3], s_parts, ".") == 2) {
            s = s_parts[1] + 0
            ms_str = s_parts[2]
            while (length(ms_str) < 3) ms_str = ms_str "0"
            ms = substr(ms_str, 1, 3) + 0
        } else {
            s = t_parts[3] + 0
            ms = 0
        }
        return days_from_civil(y, m, d) * 86400000 + h * 3600000 + min * 60000 + s * 1000 + ms
    }

    {
        t = parse_time($1, $2)
        if (t < 0) next

        if (index($0, "Dropping eSCO creation") > 0) {
            n_drops++
            drop_time[n_drops] = t
            drop_raw[n_drops] = $2
        } else if (index($0, "type = Creation") > 0) {
            n_creations++
            creation_time[n_creations] = t
        } else if (index($0, "type = Disconnection") > 0) {
            n_disconns++
            disconn_time[n_disconns] = t
        }
        if (index($0, "bridge_src=builtin_fallback") > 0) {
            n_fallbacks++
            fallback_time[n_fallbacks] = t
        }
    }

    END {
        recovered_cnt = 0
        fallback_cnt = 0
        failed_cnt = 0
        earliest_fail_raw = ""
        earliest_fail_time = ""

        for (i = 1; i <= n_drops; i++) {
            td = drop_time[i]
            c_found = 0
            min_tc = 0
            for (j = 1; j <= n_creations; j++) {
                if (creation_time[j] > td) {
                    if (!c_found || creation_time[j] < min_tc) {
                        c_found = 1
                        min_tc = creation_time[j]
                    }
                }
            }

            d_found = 0
            min_tdisc = 0
            for (j = 1; j <= n_disconns; j++) {
                if (disconn_time[j] > td && (!c_found || disconn_time[j] < min_tc)) {
                    if (!d_found || disconn_time[j] < min_tdisc) {
                        d_found = 1
                        min_tdisc = disconn_time[j]
                    }
                }
            }
            anchor = (d_found ? min_tdisc : td)

            if (c_found && min_tc <= anchor + 1500) {
                drop_status[i] = "recovered"
                recovered_cnt++
            } else {
                fb_found = 0
                for (j = 1; j <= n_fallbacks; j++) {
                    if (fallback_time[j] >= td - 2000 && fallback_time[j] <= td + 5000) {
                        fb_found = 1
                        break
                    }
                }
                if (fb_found) {
                    drop_status[i] = "fallback"
                    fallback_cnt++
                } else {
                    drop_status[i] = "FAIL"
                    failed_cnt++
                    if (earliest_fail_time == "" || td < earliest_fail_time) {
                        earliest_fail_time = td
                        earliest_fail_raw = drop_raw[i]
                    }
                }
            }
        }

        n = (n_drops + 0)
        print "drops=" n " recovered=" recovered_cnt " fallback=" fallback_cnt " failed=" failed_cnt
        for (i = 1; i <= n_drops; i++) {
            print "drop " drop_raw[i] " -> " drop_status[i]
        }

        if (failed_cnt == 0) {
            print "BT-PROOF: PASS"
            exit 0
        } else {
            print "BT-PROOF: FAIL " earliest_fail_raw
            exit 1
        }
    }
    ' "$ca_file" "$notes_file"
}

esco_log_window() {
    local start="$1"
    local end="$2"

    local start_clean="${start%%.*}"
    local end_clean="${end%%.*}"
    local start_sec
    local end_sec
    start_sec=$(date -j -f '%Y-%m-%d %H:%M:%S' "$start_clean" '+%s' 2>/dev/null || true)
    end_sec=$(date -j -f '%Y-%m-%d %H:%M:%S' "$end_clean" '+%s' 2>/dev/null || true)
    if [ -z "$start_sec" ] || [ -z "$end_sec" ] || [ "$start_sec" -gt "$end_sec" ]; then
        esco_usage
    fi

    local coreaudio_tmp
    local notes_tmp
    coreaudio_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-ca.XXXXXX")
    notes_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-notes.XXXXXX")
    trap 'rm -f "$coreaudio_tmp" "$notes_tmp"' EXIT

    /usr/bin/log show --start "$start" --end "$end" --info --debug --style compact \
        --predicate 'process == "coreaudiod" AND subsystem == "com.apple.bluetooth"' 2>/dev/null \
        | grep -E 'Dropping eSCO creation|Injecting silent Audio started|operation completed operaton type = (Creation|Disconnection)' \
        > "$coreaudio_tmp"
    local status_ca=${PIPESTATUS[0]}

    /usr/bin/log show --start "$start" --end "$end" --info --debug --style compact \
        --predicate 'subsystem == "com.razakhan.archie" AND category == "voice"' 2>/dev/null \
        | grep -F 'bridge_src=builtin_fallback' \
        > "$notes_tmp"
    local status_notes=${PIPESTATUS[0]}

    if [ "$status_ca" -ne 0 ] || [ "$status_notes" -ne 0 ]; then
        echo "BT-PROOF: FAIL log_show_error"
        exit 2
    fi

    local dictate_stderr="$HOME/Library/Logs/Dictate/dictate.stderr.log"
    if [ -f "$dictate_stderr" ]; then
        local line
        local stamp
        local l_sec
        local local_ts
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
                stamp="${BASH_REMATCH[1]}Z"
                l_sec=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" '+%s' 2>/dev/null || true)
                if [ -n "$l_sec" ] && [ "$l_sec" -ge "$start_sec" ] && [ "$l_sec" -le "$end_sec" ]; then
                    local_ts=$(date -r "$l_sec" '+%Y-%m-%d %H:%M:%S.000')
                    echo "$local_ts $line" >> "$notes_tmp"
                fi
            fi
        done < <(grep -F 'bridge_src=builtin_fallback' "$dictate_stderr" 2>/dev/null || true)
    fi

    esco_analyse "$coreaudio_tmp" "$notes_tmp"
    local rc=$?
    rm -f "$coreaudio_tmp" "$notes_tmp"
    trap - EXIT
    exit "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "--log" ]]; then
        if [ $# -ne 2 ] || ! [[ "${2:-}" =~ ^[0-9]+$ ]] || [ "${2:-0}" -le 0 ]; then
            esco_usage
        fi
        start=$(date -v-"${2}"M '+%Y-%m-%d %H:%M:%S')
        end=$(date '+%Y-%m-%d %H:%M:%S')
        esco_log_window "$start" "$end"
    elif [[ "${1:-}" == "--log-window" ]]; then
        if [ $# -ne 3 ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
            esco_usage
        fi
        esco_log_window "$2" "$3"
    elif [[ "${1:-}" == "--from-file" ]]; then
        if [ $# -lt 2 ] || [ $# -gt 3 ] || [ ! -f "${2:-}" ]; then
            esco_usage
        fi
        if [ $# -eq 3 ] && [ ! -f "${3:-}" ]; then
            esco_usage
        fi
        esco_analyse "$2" "${3:-/dev/null}"
        exit $?
    elif [[ "${1:-}" == "analyse" ]]; then
        analyse "${2:-}" "${3:-}"
        exit $?
    elif [[ $# -eq 2 ]]; then
        analyse "$1" "$2"
        exit $?
    else
        main "$@"
    fi
fi
