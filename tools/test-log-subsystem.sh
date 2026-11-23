#!/bin/bash
# Shell-only regression test; LOG_SUBSYSTEM_ROOT can point at a HEAD snapshot.
set -Eeuo pipefail
fail() { trap - ERR; printf 'P RED bt_proof_subsystem_from_env=0 %s\n' "$1"; exit 1; }
trap 'fail "${case_name:-setup}"' ERR
root=${LOG_SUBSYSTEM_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
bt="$root/tools/bt-proof.sh"
rig="$root/tools/rig/live-rig.zsh"
# A baseline without the override must fail before any absolute log call runs.
for script in "$bt" "$rig"; do
    grep -Fq 'ARCHIE_LOG_BIN:-/usr/bin/log' "$script" || fail missing_log_bin_override
    if grep -Eq '^[[:space:]]*/usr/bin/log[[:space:]]' "$script"; then fail absolute_log_call; fi
done
scratch=$(mktemp -d "${TMPDIR:-/tmp}/log-subsystem-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cat > "$scratch/bin/log" <<'STUB'
#!/bin/bash
printf '%s\n' CALL "$@" >> "$LOG_ARGV"
STUB
chmod +x "$scratch/bin/log"
export PATH="$scratch/bin:$PATH" ARCHIE_LOG_BIN="$scratch/bin/log"

run_case() (
    local case_name=$1 expected=$2 warnings=$3 mode rc
    export HOME=$(mktemp -d "$scratch/home.XXXXXX")
    export LOG_ARGV="$HOME/argv"
    unset ARCHIE_LOG_SUBSYSTEM
    mkdir -p "$HOME/Library/Application Support/Dictate"
    local config="$HOME/Library/Application Support/Dictate/build.env"
    case "$case_name" in
        env) export ARCHIE_LOG_SUBSYSTEM=com.test.subsys ;;
        file) printf '%s\n' 'ARCHIE_LOG_SUBSYSTEM=com.test.fromfile' > "$config" ;;
        default) ;;
        invalid_env) export ARCHIE_LOG_SUBSYSTEM='bad"; rm' ;;
        empty_env) export ARCHIE_LOG_SUBSYSTEM=; printf '%s\n' 'ARCHIE_LOG_SUBSYSTEM=com.test.fromfile' > "$config" ;;
        precedence) export ARCHIE_LOG_SUBSYSTEM=com.test.subsys; printf '%s\n' 'ARCHIE_LOG_SUBSYSTEM=com.test.fromfile' > "$config" ;;
        quoted) printf '%s\n' 'ARCHIE_LOG_SUBSYSTEM="com.test.fromfile"' > "$config" ;;
        exported) printf '%s\n' "export ARCHIE_LOG_SUBSYSTEM='com.test.fromfile'" > "$config" ;;
        exported_double) printf '%s\n' 'export ARCHIE_LOG_SUBSYSTEM="com.test.fromfile"' > "$config" ;;
        invalid_file) printf '%s\n' 'ARCHIE_LOG_SUBSYSTEM=bad"; rm' > "$config" ;;
        invalid_env_precedence) export ARCHIE_LOG_SUBSYSTEM='bad"; rm'; printf '%s\n' 'ARCHIE_LOG_SUBSYSTEM=com.test.fromfile' > "$config" ;;
        empty_file) printf '%s\n' 'ARCHIE_LOG_SUBSYSTEM=' > "$config" ;;
        missing_key) printf '%s\n' 'OTHER=value' > "$config" ;;
        no_source) printf '%s\n' 'touch "$HOME/sourced"' 'ARCHIE_LOG_SUBSYSTEM=com.test.fromfile' > "$config" ;;
        unmatched_quote) printf '%s\n' 'ARCHIE_LOG_SUBSYSTEM="com.test.fromfile' > "$config" ;;
        valid_characters) export ARCHIE_LOG_SUBSYSTEM=com.test.Subsys_1-2 ;;
    esac
    for mode in window minutes; do
        : > "$LOG_ARGV"
        rc=0
        if [[ "$mode" == window ]]; then
            bash "$bt" --log-window '2026-10-12 10:00:00' '2026-10-12 10:01:00' > "$HOME/out" 2> "$HOME/err" || rc=$?
        else
            bash "$bt" --log 1 > "$HOME/out" 2> "$HOME/err" || rc=$?
        fi
        [[ "$rc" -le 1 ]] || fail "$case_name-$mode-exit"
        grep -Fxq "subsystem == \"$expected\" AND category == \"voice\"" "$LOG_ARGV" || fail "$case_name-$mode-predicate"
        [[ $(grep -c '^CALL$' "$LOG_ARGV") == 2 && $(grep -c '^show$' "$LOG_ARGV") == 2 ]] || fail "$case_name-$mode-calls"
        [[ $(wc -l < "$HOME/err" | tr -d ' ') == "$warnings" ]] || fail "$case_name-$mode-warning-count"
        if [[ "$warnings" == 1 ]]; then
            grep -Fxq 'WARNING: invalid ARCHIE_LOG_SUBSYSTEM; using com.example.archie' "$HOME/err" || fail "$case_name-$mode-warning"
        fi
    done
    # Live streaming needs hardware/GO; the early seam calls its actual resolver.
    zsh -f "$rig" --print-subsystem > "$HOME/out" 2> "$HOME/err"
    [[ $(cat "$HOME/out") == "$expected" ]] || fail "$case_name-rig-value"
    [[ $(wc -l < "$HOME/err" | tr -d ' ') == "$warnings" ]] || fail "$case_name-rig-warning-count"
    if [[ "$warnings" == 1 ]]; then
        grep -Fxq 'WARNING: invalid ARCHIE_LOG_SUBSYSTEM; using com.example.archie' "$HOME/err" || fail "$case_name-rig-warning"
    fi
    [[ ! -e "$HOME/sourced" ]] || fail "$case_name-sourced"
)
run_case env com.test.subsys 0
run_case file com.test.fromfile 0
run_case default com.example.archie 0
run_case invalid_env com.example.archie 1
run_case empty_env com.test.fromfile 0
run_case precedence com.test.subsys 0
run_case quoted com.test.fromfile 0
run_case exported com.test.fromfile 0
run_case exported_double com.test.fromfile 0
run_case invalid_file com.example.archie 1
run_case invalid_env_precedence com.example.archie 1
run_case empty_file com.example.archie 0
run_case missing_key com.example.archie 0
run_case no_source com.test.fromfile 0
run_case unmatched_quote com.example.archie 1
run_case valid_characters com.test.Subsys_1-2 0
printf '%s\n' 'P GREEN bt_proof_subsystem_from_env=1'
