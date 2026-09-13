#!/bin/sh
# Contract test for the real stream-resolution rebuild smoke harness.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE="$ROOT/Scripts/run-real-local-resize-smoke.sh"

[ -x "$SMOKE" ]
grep -F 'tcp-local-verification' "$SMOKE" >/dev/null
grep -F 'SensoriumLocalWorkspaceInputProbe' "$SMOKE" >/dev/null
grep -F 'enter-resize' "$SMOKE" >/dev/null
grep -F 'SENSORIUM_ALLOW_RESIZE_SMOKE=1' "$SMOKE" >/dev/null
grep -F 'resize_smoke_complete=yes' "$SMOKE" >/dev/null
grep -F 'resize_stage_' "$SMOKE" >/dev/null
grep -F '"baseline"' "$SMOKE" >/dev/null
grep -F '"scaled_up"' "$SMOKE" >/dev/null
grep -F '"scaled_down"' "$SMOKE" >/dev/null
grep -F 'stream scale now' "$SMOKE" >/dev/null
grep -F 'compare-display-inventory.py' "$SMOKE" >/dev/null
grep -F 'display-inventory-pre.json' "$SMOKE" >/dev/null
grep -F 'display-inventory-post.json' "$SMOKE" >/dev/null

# A screen that is asleep or a session that is locked must fail fast, before
# pairing or serving even start, with a BLOCKED line naming the remedy.
grep -F 'check-display-active.py' "$SMOKE" >/dev/null
grep -F 'check-display-active.py "$STATE/display-inventory-pre.json" || exit 3' "$SMOKE" >/dev/null

# Every failure path must explain why and name a log to read, and the script
# must not be able to exit silently under `set -e`.
grep -E 'trap [a-zA-Z_]+ ERR' "$SMOKE" >/dev/null
fail_calls="$(grep -cF '|| fail ' "$SMOKE")"
[ "$fail_calls" -ge 5 ]

if grep -Ei 'SensoriumCanvasExerciser|package-apps\.sh|zip|unzip|sudo|system_profiler' "$SMOKE" >/dev/null; then
  echo 'Resize smoke must use the raw SwiftPM probe binary, not a packaged app, exerciser, archive, or privilege escalation.' >&2
  exit 1
fi

printf 'PASS: real local resize smoke harness contract\n'
