#!/bin/sh
# Contract test for the real stuck-input focus-release smoke harness.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE="$ROOT/Scripts/run-real-local-focus-release-smoke.sh"

[ -x "$SMOKE" ]
grep -F 'tcp-local-verification' "$SMOKE" >/dev/null
grep -F 'SensoriumLocalWorkspaceInputProbe' "$SMOKE" >/dev/null
grep -F 'enter-focus-release' "$SMOKE" >/dev/null
grep -F 'SENSORIUM_ALLOW_FOCUS_RELEASE_SMOKE=1' "$SMOKE" >/dev/null
grep -F 'focus_release_smoke_complete=yes' "$SMOKE" >/dev/null
grep -F 'focus_release_held_shift_down=true' "$SMOKE" >/dev/null
grep -F 'focus_release_held_left_button_down=true' "$SMOKE" >/dev/null
grep -F 'focus_release_after_shift_down=false' "$SMOKE" >/dev/null
grep -F 'focus_release_after_left_button_down=false' "$SMOKE" >/dev/null
grep -F 'focus_release_shift_flag_still_set=false' "$SMOKE" >/dev/null
grep -F 'compare-display-inventory.py' "$SMOKE" >/dev/null
grep -F 'display-inventory-pre.json' "$SMOKE" >/dev/null
grep -F 'display-inventory-post.json' "$SMOKE" >/dev/null
grep -F 'classify-host-permission-blocker.py' "$SMOKE" >/dev/null

# A screen that is asleep or a session that is locked must fail fast, before
# pairing or serving even start, with a BLOCKED line naming the remedy.
grep -F 'check-display-active.py' "$SMOKE" >/dev/null
grep -F 'check-display-active.py "$STATE/display-inventory-pre.json" || exit 3' "$SMOKE" >/dev/null

# A person actively using this machine makes the host workspace unable to come
# frontmost -- the same `workspace_focus_confirmed=false` a genuine defect
# would produce. That must be reported as BLOCKED with the remedy (leave the
# machine alone), not as an opaque FAIL, and classified from the probe log via
# the fixture-tested classifier rather than re-implemented inline.
FOCUS_CLASSIFIER="$ROOT/Scripts/classify-workspace-focus-blocker.py"
FOCUS_CLASSIFIER_TEST="$ROOT/Scripts/test-classify-workspace-focus-blocker.py"
[ -x "$FOCUS_CLASSIFIER" ]
[ -x "$FOCUS_CLASSIFIER_TEST" ]
grep -F 'classify-workspace-focus-blocker.py' "$SMOKE" >/dev/null
grep -F 'echo "BLOCKED: $focus_reason"' "$SMOKE" >/dev/null

# Every failure path must explain why and name a log to read, and the script
# must not be able to exit silently under `set -e`.
grep -E 'trap [a-zA-Z_]+ ERR' "$SMOKE" >/dev/null
fail_calls="$(grep -cF '|| fail_with_diagnosis ' "$SMOKE")"
[ "$fail_calls" -ge 5 ]

if grep -Ei 'SensoriumCanvasExerciser|package-apps\.sh|zip|unzip|sudo|system_profiler' "$SMOKE" >/dev/null; then
  echo 'Focus-release smoke must use the raw SwiftPM probe binary, not a packaged app, exerciser, archive, or privilege escalation.' >&2
  exit 1
fi

# The probe source itself must trigger focus loss through the real AppKit
# notifications, never by calling the release method directly, and must
# assert on real CGEventSource state, not in-process bookkeeping.
PROBE_SOURCE="$ROOT/Sources/SensoriumLocalWorkspaceInputProbe/main.swift"
grep -F 'NSWindow.didResignKeyNotification' "$PROBE_SOURCE" >/dev/null
grep -F 'NSApplication.didResignActiveNotification' "$PROBE_SOURCE" >/dev/null
grep -F 'CGEventSource.keyState' "$PROBE_SOURCE" >/dev/null
grep -F 'CGEventSource.buttonState' "$PROBE_SOURCE" >/dev/null
grep -F 'SENSORIUM_ALLOW_FOCUS_RELEASE_SMOKE' "$PROBE_SOURCE" >/dev/null

printf 'PASS: real local focus release smoke harness contract\n'
