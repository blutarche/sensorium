#!/usr/bin/env bash
# Exercise real title-bar double-clicks without a host or the outer desktop.
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
    [ "$ready" = 1 ] || { echo 'FAIL: maximized fixture did not become ready' >&2; exit 1; }
    python3 "$root/Scripts/linux-titlebar-maximize-input.py" "$output"
    python3 - "$output/client.log" <<'PY'
from pathlib import Path
import re
import sys
source = Path(sys.argv[1]).read_text()
events = list(re.finditer(r'xdg_toplevel#\d+\.configure\((\d+), (\d+),', source))
expected = [(1920, 1034), (1280, 800)] * 3 + [(1920, 1034)]
observed = [(int(m[1]), int(m[2])) for m in events[-7:]]
if observed != expected:
    raise SystemExit(f'FAIL: titlebar configure sequence was {observed}')
parent = re.search(r'get_viewport\(new id wp_viewport#(\d+), wl_surface#(\d+)\)', source)
if parent is None:
    raise SystemExit('FAIL: no parent viewport was created')
viewport, surface = parent.groups()
for index, (event, size) in enumerate(zip(events[-7:], expected)):
    end = events[-7:][index + 1].start() if index < 6 else len(source)
    segment = source[event.end():end]
    destination = f'wp_viewport#{viewport}.set_destination({size[0]}, {size[1]})'
    commit = f'wl_surface#{surface}.commit()'
    if destination not in segment or commit not in segment.split(destination, 1)[-1]:
        raise SystemExit('FAIL: parent viewport did not commit the configured size')
print('PASS: six real titlebar double-clicks restored/maximized three times; parent viewport committed every configured size')
PY
    for cycle in 2 3; do
        cmp -s "$output/maximize-maximized.png" "$output/maximize-maximized-$cycle.png" || {
            echo 'FAIL: maximized picture differed after a repeated titlebar double-click' >&2; exit 1;
        }
    done
    echo 'PASS: all three maximized compositor screenshots contain the same picture'
    wait "$client_pid"
    trap - EXIT
    exit 0
fi
probe=${1:-"$root/.build/release/SensoriumViewerProbe"}
output=${2:-"$root/Artifacts/verify/linux-titlebar-maximize"}
[ -x "$probe" ] || { echo 'FAIL: build SensoriumViewerProbe first' >&2; exit 1; }
mkdir -p "$output" "$root/.build" "$output/home" "$output/config" "$output/data" "$output/cache"
output=$(cd "$output" && pwd)
runtime=$(mktemp -d "$root/.build/max-runtime.XXXXXX")
trap 'rm -rf "$runtime"' EXIT
export XDG_RUNTIME_DIR="$runtime"
export HOME="$output/home"
export XDG_CONFIG_HOME="$output/config"
export XDG_DATA_HOME="$output/data"
export XDG_CACHE_HOME="$output/cache"
"$root/Scripts/linux-headless-session.sh" --width 1920 --height 1080 --seconds 15 --wait 25 \
    --shot "$output/final.png" --log "$output/session.log" -- \
    "$0" --inner "$probe" "$output"
