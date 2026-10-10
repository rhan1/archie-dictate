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

    local LOG="$HOME/Library/Logs/Dictate/dictate.stderr.log"
    local START_LINES=0
    if [ -f "$LOG" ]; then
        START_LINES=$(wc -l < "$LOG" | tr -d '[:space:]')
    fi
    START_LINES=${START_LINES:-0}

    local PROBE_LOG="/tmp/bt-proof.probe.log"
    local PID=""
    swift "$REPO/tools/probes/bt-probe.swift" 75 > "$PROBE_LOG" 2>/dev/null &
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "analyse" ]]; then
        analyse "${2:-}" "${3:-}"
        exit $?
    elif [[ $# -eq 2 ]]; then
        analyse "$1" "$2"
        exit $?
    else
        main "$@"
    fi
fi
