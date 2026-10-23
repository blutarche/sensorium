#!/bin/sh
# Contract for the real lock-screen typing smoke.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE="$ROOT/Scripts/run-real-local-lock-typing-smoke.sh"

[ -x "$SMOKE" ]
grep -F 'SensoriumLocalHostScreenProbe' "$SMOKE" >/dev/null
grep -F 'Scripts/package-apps.sh' "$SMOKE" >/dev/null
grep -F '/usr/bin/open -n -W' "$SMOKE" >/dev/null
grep -F 'lock-typing' "$SMOKE" >/dev/null
grep -F 'lock_typing_field_changed=yes' "$SMOKE" >/dev/null
grep -F 'PASS: real local lock typing smoke' "$SMOKE" >/dev/null

# The smoke locks the machine, so it must refuse to start without an explicit
# opt-in, and must do so before it builds or launches anything.
grep -F 'SENSORIUM_ALLOW_LOCK' "$SMOKE" >/dev/null
guard_line="$(grep -nF 'SENSORIUM_ALLOW_LOCK' "$SMOKE" | tail -n 1 | cut -d: -f1)"
first_build_line="$(grep -nF 'swift build' "$SMOKE" | head -n 1 | cut -d: -f1)"
[ "$guard_line" -lt "$first_build_line" ]
refusal_status=0
env -u SENSORIUM_ALLOW_LOCK "$SMOKE" >/dev/null 2>&1 || refusal_status=$?
if [ "$refusal_status" != 2 ]; then
  echo 'The lock typing smoke did not refuse to run without SENSORIUM_ALLOW_LOCK=1.' >&2
  exit 1
fi

# The host under test can be chosen, and the script says it leaves the machine locked.
grep -F 'HOST_APP="${HOST_APP:-' "$SMOKE" >/dev/null
grep -F 'left locked' "$SMOKE" >/dev/null
# It passes only when the probe left the password field empty.
grep -F 'lock_typing_field_cleared=yes' "$SMOKE" >/dev/null

# It also proves the viewer-driven display-mode round trip on the locked
# machine: the mode change applied (or the display offers only one mode), the
# display came back to the mode it had, and the display inventory is unchanged
# once the host is stopped.
grep -F 'mode_applied' "$SMOKE" >/dev/null
grep -F 'mode_restored' "$SMOKE" >/dev/null
grep -F 'the display mode change did not apply' "$SMOKE" >/dev/null
grep -F 'the display was not restored to the mode it was on before' "$SMOKE" >/dev/null
grep -F 'Scripts/display_inventory.swift' "$SMOKE" >/dev/null
grep -F 'Scripts/compare-display-inventory.py' "$SMOKE" >/dev/null
grep -F 'the display inventory changed during teardown' "$SMOKE" >/dev/null
last_stop_line="$(grep -n '^stop_host$' "$SMOKE" | tail -n 1 | cut -d: -f1)"
post_inventory_line="$(grep -nF 'display-inventory-post.json' "$SMOKE" | head -n 1 | cut -d: -f1)"
[ "$last_stop_line" -lt "$post_inventory_line" ]

# Throwaway state, never the real Application Support.
grep -F 'STATE="$ROOT/.build/real-local-lock-typing-smoke"' "$SMOKE" >/dev/null
grep -F 'HOST_HOME="$STATE/host"' "$SMOKE" >/dev/null
grep -F 'CFFIXED_USER_HOME="$HOST_HOME"' "$SMOKE" >/dev/null
grep -F 'CFFIXED_USER_HOME="$CLIENT_HOME"' "$SMOKE" >/dev/null
grep -F 'ARMING_FILE="$HOST_HOME/Library/Application Support/Sensorium/host-screen-arming.json"' "$SMOKE" >/dev/null

# The host is always stopped with a trapped SIGTERM, and the script cannot
# exit silently under set -e.
grep -F 'kill -TERM' "$SMOKE" >/dev/null
grep -E 'trap [a-zA-Z_]+ EXIT' "$SMOKE" >/dev/null
grep -E 'trap [a-zA-Z_]+ ERR' "$SMOKE" >/dev/null

if grep -Ei 'SensoriumCanvasExerciser|screencapture|displayplacer|zip|unzip|sudo|system_profiler|defaults |launchctl' "$SMOKE" >/dev/null; then
  echo 'Lock typing smoke must use the product host and viewer without diagnostic capture, display tools, or privilege escalation.' >&2
  exit 1
fi

sh "$ROOT/Scripts/assert-smoke-isolated.sh" "$SMOKE"

printf 'PASS: real local lock typing smoke harness contract\n'
