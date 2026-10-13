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
    echo "Usage: $0 [--log <minutes> | --log-window '<start>' '<end>' | --from-file <file> [<file2> ...] | analyse <stderr> <probe>]" >&2
    exit 2
}

esco_analyse() {
    local stream_file="$1"

    if [ ! -r "$stream_file" ]; then
        echo "BT-PROOF: FAIL parser_error"
        return 1
    fi

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
        if (length(d_parts[1]) != 4 || length(d_parts[2]) != 2 || length(d_parts[3]) != 2) return -1
        if (d_parts[1] !~ /^[0-9]{4}$/ || d_parts[2] !~ /^[0-9]{2}$/ || d_parts[3] !~ /^[0-9]{2}$/) return -1
        y = d_parts[1] + 0
        m = d_parts[2] + 0
        d = d_parts[3] + 0
        if (split(t_str, t_parts, ":") != 3) return -1
        if (length(t_parts[1]) != 2 || length(t_parts[2]) != 2) return -1
        if (t_parts[1] !~ /^[0-9]{2}$/ || t_parts[2] !~ /^[0-9]{2}$/) return -1
        h = t_parts[1] + 0
        min = t_parts[2] + 0
        if (split(t_parts[3], s_parts, ".") == 2) {
            if (s_parts[1] !~ /^[0-9]{2}$/ || s_parts[2] !~ /^[0-9]+$/) return -1
            s = s_parts[1] + 0
            ms_str = s_parts[2]
            while (length(ms_str) < 3) ms_str = ms_str "0"
            ms = substr(ms_str, 1, 3) + 0
        } else {
            if (t_parts[3] !~ /^[0-9]{2}$/) return -1
            s = t_parts[3] + 0
            ms = 0
        }
        return days_from_civil(y, m, d) * 86400000 + h * 3600000 + min * 60000 + s * 1000 + ms
    }

    function format_raw_time(t_str,   t_parts, s_parts, ms_str) {
        if (split(t_str, t_parts, ":") != 3) return t_str
        if (split(t_parts[3], s_parts, ".") == 2) {
            ms_str = s_parts[2]
            while (length(ms_str) < 3) ms_str = ms_str "0"
            return t_parts[1] ":" t_parts[2] ":" s_parts[1] "." substr(ms_str, 1, 3)
        } else {
            return t_parts[1] ":" t_parts[2] ":" t_parts[3] ".000"
        }
    }

    function extract_field(s, key,   m) {
        if (match(s, "(^|[ \t])" key "=[^ \t\r\n]+")) {
            m = substr(s, RSTART, RLENGTH)
            sub("^[ \t]*" key "=", "", m)
            return m
        }
        return ""
    }

    function has_field(s, key) {
        return match(s, "(^|[ \t])" key "=[^ \t\r\n]+") > 0
    }

    BEGIN {
        RECOVERY_SIGNAL_MAX_MS = 3000
        FALLBACK_MAX_AFTER_DROP_MS = 2000
        CAPTURE_INTERVALS_MAX = 400
    }

    {
        t = parse_time($1, $2)
        if (t < 0) next

        t_raw = format_raw_time($2)
        ev_dev = (has_field($0, "device") ? extract_field($0, "device") : "")

        if (index($0, "Dropping eSCO creation") > 0) {
            n_drops++
            drop_t[n_drops] = t
            drop_raw[n_drops] = t_raw
            drop_sess[n_drops] = ""
            drop_dev[n_drops] = ev_dev
        }

        if (index($0, "operaton type = Creation") > 0 || index($0, "operation type = Creation") > 0) {
            n_creations++
            creation_t[n_creations] = t
            creation_raw[n_creations] = t_raw
            creation_sess[n_creations] = ""
            creation_dev[n_creations] = ev_dev
        }

        if (index($0, "bridge_src=builtin_fallback") > 0) {
            n_fallbacks++
            fallback_t[n_fallbacks] = t
            fallback_raw[n_fallbacks] = t_raw
            fallback_sess[n_fallbacks] = ""
            fallback_dev[n_fallbacks] = ev_dev
            if (has_field($0, "builtin_fresh_at_fallback")) {
                fallback_fresh[n_fallbacks] = extract_field($0, "builtin_fresh_at_fallback") + 0
            } else {
                fallback_fresh[n_fallbacks] = -1
            }
        }

        if (has_field($0, "builtin_fresh_at_fallback")) {
            n_freshness++
            freshness_t[n_freshness] = t
            freshness_val[n_freshness] = extract_field($0, "builtin_fresh_at_fallback") + 0
        }

        if (index($0, "headset_signal_start=1") > 0) {
            n_headset_signals++
            headset_signal_t[n_headset_signals] = t
            headset_signal_raw[n_headset_signals] = t_raw
            headset_signal_sess[n_headset_signals] = ""
            headset_signal_dev[n_headset_signals] = ev_dev
        }

        if (has_field($0, "session")) {
            saw_session_note = 1
            sid = extract_field($0, "session")
            ev = extract_field($0, "event")
            if (ev == "start") {
                if (!session_seen[sid]) {
                    session_seen[sid] = 1
                    n_sessions++
                    session_list[n_sessions] = sid
                    session_start_cnt[sid] = 1
                    session_start_t[sid] = t
                } else {
                    session_duplicate[sid] = 1
                    session_start_cnt[sid]++
                }
            } else if (ev == "end") {
                if (!session_seen[sid]) {
                    session_seen[sid] = 1
                    n_sessions++
                    session_list[n_sessions] = sid
                    session_missing_start[sid] = 1
                    session_end_cnt[sid] = 1
                    session_end_t[sid] = t
                } else {
                    session_end_cnt[sid]++
                    session_end_t[sid] = t
                }
                if (has_field($0, "outcome")) {
                    session_has_outcome[sid] = 1
                    session_outcome[sid] = extract_field($0, "outcome")
                }
                if (has_field($0, "duration_ms")) {
                    session_has_duration_ms[sid] = 1
                    session_duration_ms[sid] = extract_field($0, "duration_ms") + 0
                }
                if (has_field($0, "bytes")) {
                    session_has_bytes[sid] = 1
                    session_bytes[sid] = extract_field($0, "bytes") + 0
                }
                if (has_field($0, "chars")) {
                    session_has_chars[sid] = 1
                    session_chars[sid] = extract_field($0, "chars") + 0
                }
                if (has_field($0, "recording_ms")) {
                    session_has_recording_ms[sid] = 1
                    session_recording_ms[sid] = extract_field($0, "recording_ms") + 0
                }
                if (has_field($0, "capture_intervals")) {
                    session_has_capture_intervals[sid] = 1
                    session_capture_intervals[sid] = extract_field($0, "capture_intervals")
                }
                if (has_field($0, "speech_sections")) {
                    session_has_speech_sections[sid] = 1
                    session_speech_sections[sid] = extract_field($0, "speech_sections") + 0
                }
                if (has_field($0, "builtin_frames_after_fallback")) {
                    session_has_builtin_frames[sid] = 1
                    session_builtin_frames[sid] = extract_field($0, "builtin_frames_after_fallback") + 0
                }
                if (has_field($0, "capture_intervals_truncated")) {
                    session_has_truncated[sid] = 1
                    session_truncated[sid] = extract_field($0, "capture_intervals_truncated") + 0
                }
                if (has_field($0, "headset_carried_ms")) {
                    session_has_headset_carried_ms[sid] = 1
                    session_headset_carried_ms[sid] = extract_field($0, "headset_carried_ms") + 0
                }
                if (has_field($0, "carrier")) {
                    session_has_carrier[sid] = 1
                    session_carrier[sid] = extract_field($0, "carrier")
                }
                if (has_field($0, "device")) {
                    session_has_device[sid] = 1
                    session_device[sid] = extract_field($0, "device")
                }
            }
        }

        if (match($0, "(^|[ \t])duration=[0-9]+(\\.[0-9]+)?s") && has_field($0, "bytes") && has_field($0, "latency_ms") && has_field($0, "chars") && has_field($0, "app") && has_field($0, "outcome")) {
            n_legacy_lines++
            legacy_t[n_legacy_lines] = t
            legacy_raw[n_legacy_lines] = t_raw
            legacy_line[n_legacy_lines] = $0
        }
    }

    END {
        tot_pass = 0
        tot_held = 0
        tot_cancelled = 0
        tot_failed = 0
        tot_recovered = 0
        tot_successful_fallbacks = 0
        drops_outside_sessions = 0

        if (!saw_session_note && n_legacy_lines > 0) {
            for (k = 1; k <= n_legacy_lines; k++) {
                lline = legacy_line[k]
                lt = legacy_t[k]
                lraw = legacy_raw[k]

                split(lraw, r_parts, ":")
                split(r_parts[3], sec_parts, ".")
                legacy_id = "legacy-" r_parts[1] r_parts[2] sec_parts[1]

                dur_s_str = extract_field(lline, "duration")
                sub(/s$/, "", dur_s_str)
                dur_ms_val = (dur_s_str + 0) * 1000

                n_sessions++
                session_list[n_sessions] = legacy_id
                session_seen[legacy_id] = 1
                session_start_cnt[legacy_id] = 1
                session_end_cnt[legacy_id] = 1
                session_start_t[legacy_id] = lt - dur_ms_val - 1000
                session_end_t[legacy_id] = lt + 1000

                session_has_outcome[legacy_id] = 1
                session_outcome[legacy_id] = extract_field(lline, "outcome")

                session_has_duration_ms[legacy_id] = 1
                session_duration_ms[legacy_id] = dur_ms_val

                session_has_bytes[legacy_id] = 1
                session_bytes[legacy_id] = extract_field(lline, "bytes") + 0

                session_has_chars[legacy_id] = 1
                session_chars[legacy_id] = extract_field(lline, "chars") + 0
            }
        }

        for (i = 1; i <= n_sessions; i++) {
            sid = session_list[i]
            if (session_start_cnt[sid] == 0) session_missing_start[sid] = 1
            if (session_end_cnt[sid] == 0) session_missing_end[sid] = 1
        }

        for (d = 1; d <= n_drops; d++) {
            drop_sess[d] = ""
            d_matches = 0
            for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
                sid = session_list[s_idx]
                if (session_start_cnt[sid] >= 1 && session_end_cnt[sid] >= 1) {
                    if (session_start_t[sid] <= drop_t[d] && drop_t[d] <= session_end_t[sid]) {
                        if (drop_dev[d] != "" && session_has_device[sid] && session_device[sid] != drop_dev[d]) {
                            # device mismatch
                        } else {
                            d_matches++
                            d_matched_sids[d_matches] = sid
                        }
                    }
                }
            }
            if (d_matches == 1) {
                drop_sess[d] = d_matched_sids[1]
                sess_drop_cnt[d_matched_sids[1]]++
            } else if (d_matches > 1) {
                drop_status[d] = "FAIL"
                for (m = 1; m <= d_matches; m++) {
                    msid = d_matched_sids[m]
                    session_ambiguous_cnt[msid]++
                    session_ambiguous_reason[msid, session_ambiguous_cnt[msid]] = "ambiguous_session@" drop_raw[d]
                }
            } else {
                drops_outside_sessions++
                drop_status[d] = "FAIL"
            }
        }

        for (c = 1; c <= n_creations; c++) {
            creation_sess[c] = ""
            c_matches = 0
            for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
                sid = session_list[s_idx]
                if (session_start_cnt[sid] >= 1 && session_end_cnt[sid] >= 1) {
                    if (session_start_t[sid] <= creation_t[c] && creation_t[c] <= session_end_t[sid]) {
                        if (creation_dev[c] != "" && session_has_device[sid] && session_device[sid] != creation_dev[c]) {
                            # device mismatch
                        } else {
                            c_matches++
                            c_matched_sids[c_matches] = sid
                        }
                    }
                }
            }
            if (c_matches == 1) {
                creation_sess[c] = c_matched_sids[1]
            } else if (c_matches > 1) {
                for (m = 1; m <= c_matches; m++) {
                    msid = c_matched_sids[m]
                    session_ambiguous_cnt[msid]++
                    session_ambiguous_reason[msid, session_ambiguous_cnt[msid]] = "ambiguous_session@" creation_raw[c]
                }
            }
        }

        for (f = 1; f <= n_fallbacks; f++) {
            fallback_sess[f] = ""
            f_matches = 0
            for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
                sid = session_list[s_idx]
                if (session_start_cnt[sid] >= 1 && session_end_cnt[sid] >= 1) {
                    if (session_start_t[sid] <= fallback_t[f] && fallback_t[f] <= session_end_t[sid]) {
                        if (fallback_dev[f] != "" && session_has_device[sid] && session_device[sid] != fallback_dev[f]) {
                            # device mismatch
                        } else {
                            f_matches++
                            f_matched_sids[f_matches] = sid
                        }
                    }
                }
            }
            if (f_matches == 1) {
                fallback_sess[f] = f_matched_sids[1]
            } else if (f_matches > 1) {
                for (m = 1; m <= f_matches; m++) {
                    msid = f_matched_sids[m]
                    session_ambiguous_cnt[msid]++
                    session_ambiguous_reason[msid, session_ambiguous_cnt[msid]] = "ambiguous_session@" fallback_raw[f]
                }
            }
        }

        for (h = 1; h <= n_headset_signals; h++) {
            headset_signal_sess[h] = ""
            h_matches = 0
            for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
                sid = session_list[s_idx]
                if (session_start_cnt[sid] >= 1 && session_end_cnt[sid] >= 1) {
                    if (session_start_t[sid] <= headset_signal_t[h] && headset_signal_t[h] <= session_end_t[sid]) {
                        if (headset_signal_dev[h] != "" && session_has_device[sid] && session_device[sid] != headset_signal_dev[h]) {
                            # device mismatch
                        } else {
                            h_matches++
                            h_matched_sids[h_matches] = sid
                        }
                    }
                }
            }
            if (h_matches == 1) {
                headset_signal_sess[h] = h_matched_sids[1]
            } else if (h_matches > 1) {
                for (m = 1; m <= h_matches; m++) {
                    msid = h_matched_sids[m]
                    session_ambiguous_cnt[msid]++
                    session_ambiguous_reason[msid, session_ambiguous_cnt[msid]] = "ambiguous_session@" headset_signal_raw[h]
                }
            }
        }

        for (f = 1; f <= n_fallbacks; f++) {
            if (fallback_fresh[f] == -1) {
                tf = fallback_t[f]
                fsid = fallback_sess[f]
                best_diff = 999999
                found_val = -1
                for (k = 1; k <= n_freshness; k++) {
                    diff = freshness_t[k] - tf
                    if (diff < 0) abs_diff = -diff; else abs_diff = diff
                    if (abs_diff <= 50) {
                        if (fsid == "" || (session_start_t[fsid] <= freshness_t[k] && freshness_t[k] <= session_end_t[fsid])) {
                            if (abs_diff < best_diff) {
                                best_diff = abs_diff
                                found_val = freshness_val[k]
                            }
                        }
                    }
                }
                if (found_val >= 0) fallback_fresh[f] = found_val
            }
        }

        for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
            sid = session_list[s_idx]
            n_r = 0

            if (session_duplicate[sid]) {
                n_r++; reasons[n_r] = "duplicate_session"
            }
            if (session_missing_start[sid]) {
                n_r++; reasons[n_r] = "missing_start_marker"
            }
            if (session_missing_end[sid]) {
                n_r++; reasons[n_r] = "missing_end_marker"
            }
            if (session_ambiguous_cnt[sid] > 0) {
                for (a_i = 1; a_i <= session_ambiguous_cnt[sid]; a_i++) {
                    n_r++; reasons[n_r] = session_ambiguous_reason[sid, a_i]
                }
            }

            # (a) outcome
            if (!session_has_outcome[sid]) {
                n_r++; reasons[n_r] = "missing_outcome"
            } else {
                outc = session_outcome[sid]
                if (outc == "cancel") {
                    session_verdict[sid] = "CANCELLED"
                    tot_cancelled++
                    continue
                } else if (outc == "ok") {
                    # ok passes
                } else if (match(outc, /^held(:.*)?$/)) {
                    if (session_has_chars[sid] && session_chars[sid] > 0) {
                        session_is_held[sid] = 1
                    } else {
                        n_r++; reasons[n_r] = "outcome=" outc
                    }
                } else {
                    n_r++; reasons[n_r] = "outcome=" outc
                }
            }

            # (b) coverage
            is_truncated = 0
            if (session_has_truncated[sid] && session_truncated[sid] == 1) {
                is_truncated = 1
            }
            if (session_has_capture_intervals[sid] && session_capture_intervals[sid] != "none") {
                n_chk = split(session_capture_intervals[sid], chk_ints, ",")
                if (n_chk >= CAPTURE_INTERVALS_MAX) {
                    is_truncated = 1
                }
            }

            if (is_truncated) {
                n_r++; reasons[n_r] = "truncated_intervals@" sid
                session_cov_pct[sid] = "na"
            } else if (!session_has_capture_intervals[sid]) {
                n_r++; reasons[n_r] = "missing_capture_intervals"
                if (session_has_bytes[sid] && session_has_duration_ms[sid] && session_duration_ms[sid] > 0) {
                    byte_cov = (session_bytes[sid] - 44) / 48000.0 / (session_duration_ms[sid] / 1000.0)
                    pct = byte_cov * 100.0
                    pct_str = sprintf("%.1f", pct)
                    session_cov_pct[sid] = pct_str "%"
                    if (byte_cov < 0.95) {
                        n_r++; reasons[n_r] = "coverage=" pct_str "% <95%"
                    }
                } else {
                    session_cov_pct[sid] = "na"
                }
            } else {
                if (!session_has_recording_ms[sid]) {
                    n_r++; reasons[n_r] = "missing_recording_ms"
                    D = 0
                } else {
                    D = session_recording_ms[sid]
                }

                c_ints = session_capture_intervals[sid]
                if (c_ints == "none") {
                    n_intervals = 0
                } else {
                    n_intervals = split(c_ints, arr_ints, ",")
                    prev_e = -1
                    order_err = 0
                    for (i = 1; i <= n_intervals; i++) {
                        split(arr_ints[i], p, "-")
                        s_val = p[1] + 0
                        e_val = p[2] + 0
                        iv_s[i] = s_val
                        iv_e[i] = e_val
                        if (e_val <= s_val || (i > 1 && s_val < prev_e)) {
                            order_err = 1
                        }
                        prev_e = e_val
                    }
                    if (order_err) {
                        n_r++; reasons[n_r] = "duplicate_or_unordered_intervals"
                    }
                }

                A = 1000
                if (n_intervals > 0) {
                    if (iv_s[1] > A) {
                        n_r++; reasons[n_r] = "late_start=" iv_s[1] "ms"
                    }
                    if (D <= A) {
                        cov = 1.0
                    } else {
                        n_clip = 0
                        for (i = 1; i <= n_intervals; i++) {
                            cs = (iv_s[i] > A ? iv_s[i] : A)
                            ce = (iv_e[i] < D ? iv_e[i] : D)
                            if (cs < ce) {
                                n_clip++
                                clip_s[n_clip] = cs
                                clip_e[n_clip] = ce
                            }
                        }
                        for (i = 1; i <= n_clip; i++) {
                            for (j = i + 1; j <= n_clip; j++) {
                                if (clip_s[j] < clip_s[i]) {
                                    tmp = clip_s[i]; clip_s[i] = clip_s[j]; clip_s[j] = tmp
                                    tmp = clip_e[i]; clip_e[i] = clip_e[j]; clip_e[j] = tmp
                                }
                            }
                        }
                        tot_covered = 0
                        if (n_clip > 0) {
                            cur_s = clip_s[1]
                            cur_e = clip_e[1]
                            for (i = 2; i <= n_clip; i++) {
                                if (clip_s[i] <= cur_e) {
                                    if (clip_e[i] > cur_e) cur_e = clip_e[i]
                                } else {
                                    tot_covered += (cur_e - cur_s)
                                    cur_s = clip_s[i]
                                    cur_e = clip_e[i]
                                }
                            }
                            tot_covered += (cur_e - cur_s)
                        }
                        cov = tot_covered / (D - A)
                    }
                } else {
                    cov = 0.0
                }

                pct = cov * 100.0
                pct_str = sprintf("%.1f", pct)
                session_cov_pct[sid] = pct_str "%"
                if (cov < 0.95) {
                    n_r++; reasons[n_r] = "coverage=" pct_str "% <95%"
                }

                max_gap = 0
                if (n_intervals > 0) {
                    for (i = 1; i < n_intervals; i++) {
                        g = iv_s[i+1] - iv_e[i]
                        if (g > 600 && g > max_gap) max_gap = g
                    }
                    if (session_has_recording_ms[sid]) {
                        end_g = D - iv_e[n_intervals]
                        if (end_g > 600 && end_g > max_gap) max_gap = end_g
                    }
                }
                if (max_gap > 600) {
                    n_r++; reasons[n_r] = "gap=" max_gap "ms >600ms"
                }
            }

            # (c) speech
            if (!session_has_speech_sections[sid]) {
                n_r++; reasons[n_r] = "missing_speech_sections"
            } else {
                sp_sec = session_speech_sections[sid]
                if (sp_sec < 3) {
                    n_r++; reasons[n_r] = "speech_sections=" sp_sec " <3"
                }
            }

            # (d) drops inside session
            for (d = 1; d <= n_drops; d++) {
                if (drop_sess[d] == sid) {
                    td = drop_t[d]
                    rec_ok = 0
                    for (c = 1; c <= n_creations; c++) {
                        if (creation_sess[c] == sid) {
                            tc = creation_t[c]
                            if (tc > td && tc <= td + 1500) {
                                for (h = 1; h <= n_headset_signals; h++) {
                                    if (headset_signal_sess[h] == sid && headset_signal_t[h] > tc && headset_signal_t[h] <= tc + RECOVERY_SIGNAL_MAX_MS) {
                                        rec_ok = 1
                                        break
                                    }
                                }
                                if (rec_ok) break
                            }
                        }
                    }

                    if (rec_ok) {
                        drop_status[d] = "recovered"
                        sess_recovered_cnt[sid]++
                        tot_recovered++
                    } else {
                        fb_ok = 0
                        for (f = 1; f <= n_fallbacks; f++) {
                            if (fallback_sess[f] == sid) {
                                tf = fallback_t[f]
                                if (tf >= td - 2000 && tf <= td + FALLBACK_MAX_AFTER_DROP_MS && fallback_fresh[f] == 1 && session_has_builtin_frames[sid] && session_builtin_frames[sid] > 0) {
                                    fb_ok = 1
                                    break
                                }
                            }
                        }
                        if (fb_ok) {
                            drop_status[d] = "fallback"
                            sess_fallback_cnt[sid]++
                            tot_successful_fallbacks++
                        } else {
                            drop_status[d] = "FAIL"
                            n_r++; reasons[n_r] = "drop_unrecovered@" drop_raw[d]
                        }
                    }
                }
            }

            if (n_r == 0) {
                if (session_is_held[sid]) {
                    session_verdict[sid] = "HELD"
                    tot_held++
                } else {
                    session_verdict[sid] = "PASS"
                    tot_pass++
                }
            } else {
                session_verdict[sid] = "FAIL"
                tot_failed++
                session_n_reasons[sid] = n_r
                for (r_i = 1; r_i <= n_r; r_i++) {
                    session_reasons[sid, r_i] = reasons[r_i]
                }
            }
        }

        for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
            sid = session_list[s_idx]
            cov_out = (session_cov_pct[sid] != "" ? session_cov_pct[sid] : "na")
            if (session_verdict[sid] == "CANCELLED") cov_out = "na"
            outc = (session_has_outcome[sid] ? session_outcome[sid] : "missing")

            r_str = ""
            if (session_verdict[sid] == "FAIL" && session_n_reasons[sid] > 0) {
                r_str = " reasons=" session_reasons[sid, 1]
                for (r_i = 2; r_i <= session_n_reasons[sid]; r_i++) {
                    r_str = r_str "," session_reasons[sid, r_i]
                }
            }

            printf("session=%s %s outcome=%s coverage=%s drops=%d recovered=%d successful_fallbacks=%d%s\n",
                   sid, session_verdict[sid], outc, cov_out,
                   sess_drop_cnt[sid] + 0, sess_recovered_cnt[sid] + 0, sess_fallback_cnt[sid] + 0,
                   r_str)
        }

        for (d = 1; d <= n_drops; d++) {
            sess_name = (drop_sess[d] != "" && drop_sess[d] != "none" ? drop_sess[d] : "none")
            printf("drop %s session=%s -> %s\n", drop_raw[d], sess_name, drop_status[d])
        }

        printf("sessions=%d pass=%d held=%d cancelled=%d failed=%d drops=%d recovered=%d successful_fallbacks=%d drops_outside_sessions=%d\n",
               n_sessions, tot_pass, tot_held, tot_cancelled, tot_failed,
               n_drops, tot_recovered, tot_successful_fallbacks, drops_outside_sessions)

        evaluable = tot_pass + tot_held + tot_failed

        # Compute separate verdicts
        # 1. continuity: PASS | FAIL
        v_continuity = "PASS"
        if (evaluable == 0 || drops_outside_sessions > 0) {
            v_continuity = "FAIL"
        } else {
            for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
                sid = session_list[s_idx]
                if (session_duplicate[sid] || session_missing_start[sid] || session_missing_end[sid] || session_ambiguous_cnt[sid] > 0) {
                    v_continuity = "FAIL"
                    break
                }
                for (r_i = 1; r_i <= session_n_reasons[sid]; r_i++) {
                    r = session_reasons[sid, r_i]
                    if (r ~ /^(missing_capture_intervals|missing_recording_ms|duplicate_or_unordered_intervals|late_start=|coverage=|gap=|truncated_intervals@|drop_unrecovered@|ambiguous_session@)/) {
                        v_continuity = "FAIL"
                        break
                    }
                }
                if (v_continuity == "FAIL") break
            }
        }

        # 2. headset: PASS | FAIL | NA
        has_headset_carried = 0
        has_unrecovered_drop = 0
        has_headset_explicit_fail = 0
        if (n_drops > 0 && tot_recovered < n_drops && tot_successful_fallbacks < (n_drops - tot_recovered)) {
            has_unrecovered_drop = 1
        }
        for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
            sid = session_list[s_idx]
            if (session_has_headset_carried_ms[sid]) {
                if (session_headset_carried_ms[sid] > 0) {
                    has_headset_carried = 1
                } else {
                    has_headset_explicit_fail = 1
                }
            }
            if (sess_recovered_cnt[sid] > 0) {
                has_headset_carried = 1
            }
            for (r_i = 1; r_i <= session_n_reasons[sid]; r_i++) {
                r = session_reasons[sid, r_i]
                if (r ~ /^drop_unrecovered@/) {
                    has_unrecovered_drop = 1
                }
            }
        }
        if (has_unrecovered_drop || has_headset_explicit_fail) {
            v_headset = "FAIL"
        } else if (has_headset_carried) {
            v_headset = "PASS"
        } else {
            v_headset = "NA"
        }

        # 3. content: PASS | FAIL | NA
        if (evaluable == 0) {
            v_content = "NA"
        } else {
            v_content = "PASS"
            for (s_idx = 1; s_idx <= n_sessions; s_idx++) {
                sid = session_list[s_idx]
                if (session_verdict[sid] == "CANCELLED") continue
                if (!session_has_outcome[sid]) {
                    v_content = "FAIL"
                    break
                }
                outc = session_outcome[sid]
                if (outc != "ok" && !match(outc, /^held(:.*)?$/)) {
                    v_content = "FAIL"
                    break
                }
                if (!session_has_chars[sid] || session_chars[sid] <= 0) {
                    v_content = "FAIL"
                    break
                }
                if (!session_has_speech_sections[sid] || session_speech_sections[sid] < 3) {
                    v_content = "FAIL"
                    break
                }
            }
        }

        # 4. playback: NA
        v_playback = "NA"

        printf("DROPS_SEEN=%d RECOVERED=%d FALLBACKS=%d\n", n_drops, tot_recovered, tot_successful_fallbacks)
        printf("VERDICT continuity=%s\n", v_continuity)
        printf("VERDICT headset=%s\n", v_headset)
        printf("VERDICT content=%s\n", v_content)
        printf("VERDICT playback=%s\n", v_playback)
        if (evaluable == 0) {
            print "BT-PROOF: FAIL missing_sessions"
            exit 1
        } else if (tot_failed == 0) {
            print "BT-PROOF: PASS"
            exit 0
        } else {
            first_fail_idx = 0
            for (k = 1; k <= n_sessions; k++) {
                sid = session_list[k]
                if (session_verdict[sid] == "FAIL") {
                    first_fail_idx = k
                    break
                }
            }
            sid = session_list[first_fail_idx]
            fail_reasons = ""
            for (r_i = 1; r_i <= session_n_reasons[sid]; r_i++) {
                if (r_i == 1) fail_reasons = session_reasons[sid, r_i]
                else fail_reasons = fail_reasons " " session_reasons[sid, r_i]
            }
            if (n_drops > 0) {
                fail_reasons = fail_reasons " successful_fallbacks=" tot_successful_fallbacks
            }
            print "BT-PROOF: FAIL " fail_reasons
            exit 1
        }
    }
    ' "$stream_file"
    local awk_rc=$?
    if [ "$awk_rc" -ne 0 ] && [ "$awk_rc" -ne 1 ]; then
        echo "BT-PROOF: FAIL parser_error"
        return 1
    fi
    return "$awk_rc"
}

esco_from_files() {
    for f in "$@"; do
        if [ ! -r "$f" ]; then
            echo "BT-PROOF: FAIL parser_error"
            exit 1
        fi
    done
    local stream_tmp
    stream_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-stream.XXXXXX")
    trap 'rm -f "$stream_tmp"' EXIT
    sort -s -k1,2 "$@" > "$stream_tmp" 2>/dev/null
    local sort_rc=$?
    if [ "$sort_rc" -ne 0 ]; then
        echo "BT-PROOF: FAIL parser_error"
        rm -f "$stream_tmp"
        trap - EXIT
        exit 1
    fi
    esco_analyse "$stream_tmp"
    local rc=$?
    rm -f "$stream_tmp"
    trap - EXIT
    exit "$rc"
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

    local ca_tmp notes_tmp stderr_tmp dict_tmp combined_tmp stream_tmp
    ca_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-ca.XXXXXX")
    notes_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-notes.XXXXXX")
    stderr_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-stderr.XXXXXX")
    dict_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-dict.XXXXXX")
    combined_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-combined.XXXXXX")
    stream_tmp=$(mktemp "${TMPDIR:-/tmp}/bt-proof-stream.XXXXXX")
    trap 'rm -f "$ca_tmp" "$notes_tmp" "$stderr_tmp" "$dict_tmp" "$combined_tmp" "$stream_tmp"' EXIT

    /usr/bin/log show --start "$start" --end "$end" --info --debug --style compact \
        --predicate 'process == "coreaudiod" AND subsystem == "com.apple.bluetooth"' 2>/dev/null \
        | grep -E 'Dropping eSCO creation|operat(i)?on type = Creation' \
        > "$ca_tmp"
    local status_ca=${PIPESTATUS[0]}

    /usr/bin/log show --start "$start" --end "$end" --info --debug --style compact \
        --predicate 'subsystem == "com.razakhan.archie" AND category == "voice"' 2>/dev/null \
        | grep -E 'session=[A-Za-z0-9_-]+[[:space:]]+event=(start|end)|bridge_src=builtin_fallback|builtin_fresh_at_fallback=|headset_signal_start=1|dict_start' \
        > "$notes_tmp"
    local status_notes=${PIPESTATUS[0]}

    if [ "$status_ca" -ne 0 ] || [ "$status_notes" -ne 0 ]; then
        echo "BT-PROOF: FAIL log_show_error"
        exit 1
    fi

    local dictate_stderr="$HOME/Library/Logs/Dictate/dictate.stderr.log"
    if [ -f "$dictate_stderr" ]; then
        local line stamp frac text l_sec local_base ms_part local_ts
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.([0-9]+))?Z\]\ dictate:\ +(.*) ]]; then
                stamp="${BASH_REMATCH[1]}Z"
                frac="${BASH_REMATCH[3]:-}"
                text="${BASH_REMATCH[4]}"
                if [[ "$text" =~ session=[A-Za-z0-9_-]+[[:space:]]+event=(start|end)|bridge_src=builtin_fallback|builtin_fresh_at_fallback=|headset_signal_start=1|dict_start ]]; then
                    l_sec=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" '+%s' 2>/dev/null || true)
                    if [ -n "$l_sec" ] && [ "$l_sec" -ge "$start_sec" ] && [ "$l_sec" -le "$end_sec" ]; then
                        local_base=$(date -r "$l_sec" '+%Y-%m-%d %H:%M:%S')
                        if [ -n "$frac" ]; then
                            while [ ${#frac} -lt 3 ]; do frac="${frac}0"; done
                            ms_part=".${frac:0:3}"
                        else
                            ms_part=".000"
                        fi
                        local_ts="${local_base}${ms_part}"
                        echo "$local_ts dictate: $text" >> "$stderr_tmp"
                    fi
                fi
            fi
        done < <(grep -E 'session=[A-Za-z0-9_-]+[[:space:]]+event=(start|end)|bridge_src=builtin_fallback|builtin_fresh_at_fallback=|headset_signal_start=1|dict_start' "$dictate_stderr" 2>/dev/null || true)
    fi

    local dictate_log="$HOME/Library/Logs/Dictate/dictate.log"
    if [ -f "$dictate_log" ]; then
        local line d_stamp d_rest d_sec d_local_ts
        while IFS= read -r line; do
            if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})([+-][0-9]{2}):([0-9]{2})\ +(duration=.*) ]]; then
                d_stamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
                d_rest="${BASH_REMATCH[4]}"
                d_sec=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$d_stamp" '+%s' 2>/dev/null || true)
                if [ -n "$d_sec" ] && [ "$d_sec" -ge "$start_sec" ] && [ "$d_sec" -le "$end_sec" ]; then
                    d_local_ts=$(date -r "$d_sec" '+%Y-%m-%d %H:%M:%S.000')
                    echo "$d_local_ts $d_rest" >> "$dict_tmp"
                fi
            fi
        done < <(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* duration=' "$dictate_log" 2>/dev/null || true)
    fi

    cat "$ca_tmp" "$notes_tmp" "$stderr_tmp" "$dict_tmp" > "$combined_tmp"
    sort -s -k1,2 "$combined_tmp" > "$stream_tmp"
    esco_analyse "$stream_tmp"
    local rc=$?
    rm -f "$ca_tmp" "$notes_tmp" "$stderr_tmp" "$dict_tmp" "$combined_tmp" "$stream_tmp"
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
        shift
        if [ $# -lt 1 ]; then
            esco_usage
        fi
        esco_from_files "$@"
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

