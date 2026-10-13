#!/bin/zsh
# v1.13: the WAV hatch in one line — no mic, no Bluetooth, no device, no volume.
#   zsh tools/hatch-run.zsh <clip.wav> <engine|auhal> [live_pause|pause_zeros|headset_drops]
# Prints `hatch arm=… carrier=… mid_run_builtin_segments=N` and every bridge switch (`t_ms=… bridge_switch=…
# headset_peak= builtin_peak=`). HATCH_STT=1 adds Groq whisper word counts of the post-pause audio (counts
# only; the key is read from the keychain into the child's environment and never printed).
set -euo pipefail
SW="$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift"
REPO_DIR="${0:A:h:h}"
cd "$REPO_DIR"
SCRATCH="${HATCH_SCRATCH:-$REPO_DIR/.build}"
"$SW" build --scratch-path "$SCRATCH" --product DictateBench >/dev/null
BIN="$("$SW" build --scratch-path "$SCRATCH" --product DictateBench --show-bin-path)/DictateBench"
clip="${1:A}"
if [[ "${HATCH_STT:-0}" == 1 ]]; then
    GROQ_API_KEY="$(/usr/bin/security find-generic-password -w -s groq-api -a "$(id -un)")" "$BIN" hatch "$clip" "${2:?arm}" "${3:-live_pause}"
else
    "$BIN" hatch "$clip" "${2:?arm}" "${3:-live_pause}"
fi
