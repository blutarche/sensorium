#!/usr/bin/env bash
# Prove compositor wheel delivery to the real diagnostics viewport, without a host.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "${1-}" = --inner ]; then
    probe=$2
    output=$3
    case "${WAYLAND_DISPLAY-}" in sensorium-harness-*) ;; *) echo 'REFUSED: not a nested compositor' >&2; exit 2 ;; esac
    env WAYLAND_DEBUG=client "$probe" view-selftest --diagnostics-wheel >"$output/client.log" 2>&1 &
    client_pid=$!
    trap 'kill -TERM "$client_pid" 2>/dev/null || true; wait "$client_pid" 2>/dev/null || true' EXIT
    ready=0
    for _ in $(seq 1 100); do
        if grep -q 'diagnostics-wheel: ready' "$output/client.log"; then ready=1; break; fi
        kill -0 "$client_pid" 2>/dev/null || break
        sleep 0.1
    done
    [ "$ready" = 1 ] || { echo 'FAIL: diagnostics window did not become ready' >&2; exit 1; }
    python3 "$root/Scripts/linux-diagnostics-wheel-input.py" "$output"
    grep -q 'wl_pointer.*axis(' "$output/client.log" || { echo 'FAIL: compositor delivered no pointer axis events' >&2; exit 1; }
    cmp -s "$output/wheel-before.png" "$output/wheel-down.png" && { echo 'FAIL: wheel input did not change the diagnostics viewport' >&2; exit 1; }
    cmp -s "$output/wheel-before.png" "$output/wheel-up.png" || { echo 'FAIL: reverse wheel did not restore the original viewport' >&2; exit 1; }
    echo 'PASS: compositor wheel moved the diagnostics viewport and reverse wheel restored it'
    wait "$client_pid"
    trap - EXIT
    exit 0
fi
probe=${1:-"$root/.build/release/SensoriumViewerProbe"}
output=${2:-"$root/Artifacts/verify/linux-diagnostics-wheel"}
[ -x "$probe" ] || { echo 'FAIL: build SensoriumViewerProbe first' >&2; exit 1; }
mkdir -p "$output" "$output/runtime" "$output/home" "$output/config" "$output/data" "$output/cache"
output=$(cd "$output" && pwd)
chmod 700 "$output/runtime"
export XDG_RUNTIME_DIR="$output/runtime"
export HOME="$output/home"
export XDG_CONFIG_HOME="$output/config"
export XDG_DATA_HOME="$output/data"
export XDG_CACHE_HOME="$output/cache"
exec "$root/Scripts/linux-headless-session.sh" --width 960 --height 420 --seconds 12 --wait 25 \
    --shot "$output/final.png" --log "$output/session.log" -- \
    "$0" --inner "$probe" "$output"
