#!/bin/sh
# Contract test for the real local capture/decode smoke harness.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE="$ROOT/Scripts/run-real-local-video-smoke.sh"

[ -x "$SMOKE" ]
grep -F 'tcp-local-verification' "$SMOKE" >/dev/null
grep -F 'workspace started on session canvas' "$SMOKE" >/dev/null
grep -F 'workspace_frame_presented=yes' "$SMOKE" >/dev/null
grep -F 'compare-display-inventory.py' "$SMOKE" >/dev/null
grep -F 'display-inventory-pre.json' "$SMOKE" >/dev/null
grep -F 'display-inventory-post.json' "$SMOKE" >/dev/null

# A screen that is asleep or a session that is locked must fail fast, before
# pairing or serving even start, with a BLOCKED line naming the remedy.
grep -F 'check-display-active.py' "$SMOKE" >/dev/null
grep -F 'check-display-active.py "$STATE/display-inventory-pre.json" || exit 3' "$SMOKE" >/dev/null
if grep -Ei 'SensoriumCanvasExerciser|zip|unzip|sudo|system_profiler' "$SMOKE" >/dev/null; then
  echo 'Local video smoke must use the product workspace, not an exerciser, archive, privilege escalation, or System Profiler.' >&2
  exit 1
fi

printf 'PASS: real local video smoke harness contract\n'
