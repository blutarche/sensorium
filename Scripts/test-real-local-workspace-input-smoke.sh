#!/bin/sh
# Contract for the real viewer-to-workspace input smoke.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE="$ROOT/Scripts/run-real-local-workspace-input-smoke.sh"

[ -x "$SMOKE" ]
grep -F 'SensoriumLocalWorkspaceInputProbe' "$SMOKE" >/dev/null
grep -F 'Sensorium workspace: text input observed' "$SMOKE" >/dev/null
grep -F 'viewer_presented_frames=' "$SMOKE" >/dev/null
grep -F 'workspace_input_sent=yes' "$SMOKE" >/dev/null
grep -F 'compare-display-inventory.py' "$SMOKE" >/dev/null
grep -F 'display-inventory-pre.json' "$SMOKE" >/dev/null
grep -F 'display-inventory-post.json' "$SMOKE" >/dev/null
grep -F 'Scripts/package-apps.sh' "$SMOKE" >/dev/null

# A screen that is asleep or a session that is locked must fail fast, before
# pairing or serving even start, with a BLOCKED line naming the remedy —
# never the cryptic "the probe's 'enter' step failed" this preflight
# replaces.
grep -F 'check-display-active.py' "$SMOKE" >/dev/null
grep -F 'check-display-active.py "$STATE/display-inventory-pre.json" || exit 3' "$SMOKE" >/dev/null
grep -F '/usr/bin/open -n -W' "$SMOKE" >/dev/null
grep -F 'BLOCKED: packaged host requires' "$SMOKE" >/dev/null
if grep -F 'workspace_input_delivered' "$SMOKE" >/dev/null; then
  echo 'Workspace input smoke must not claim host-side input delivery the client cannot observe; use workspace_input_sent.' >&2
  exit 1
fi

# Missing Accessibility and missing Screen Recording must each be reportable
# on their own: the old contract required both markers together, which made
# the common single-permission case fall through to a silent set -e exit.
grep -F 'BLOCKED: packaged host requires user-granted Accessibility before local viewer/control acceptance can run.' "$SMOKE" >/dev/null
grep -F 'BLOCKED: packaged host requires user-granted Screen Recording before local viewer/control acceptance can run.' "$SMOKE" >/dev/null
grep -F 'BLOCKED: packaged host requires user-granted Accessibility and Screen Recording before local viewer/control acceptance can run.' "$SMOKE" >/dev/null

# A person actively using this Mac makes the host workspace unable to come
# frontmost -- the same `workspace_focus_confirmed=false` a genuine defect
# would produce. That must be reported as BLOCKED with the remedy (leave the
# Mac alone), not as an opaque FAIL, and classified from the probe log via
# the fixture-tested classifier rather than re-implemented inline.
FOCUS_CLASSIFIER="$ROOT/Scripts/classify-workspace-focus-blocker.py"
FOCUS_CLASSIFIER_TEST="$ROOT/Scripts/test-classify-workspace-focus-blocker.py"
[ -x "$FOCUS_CLASSIFIER" ]
[ -x "$FOCUS_CLASSIFIER_TEST" ]
grep -F 'classify-workspace-focus-blocker.py' "$SMOKE" >/dev/null
grep -F 'echo "BLOCKED: $focus_reason"' "$SMOKE" >/dev/null

# Permission-marker classification must be behaviour-tested against fixture
# log text, not just grepped for as a literal string in this script, and
# must be reused by every failure path, not only the probe `enter` failure.
CLASSIFIER="$ROOT/Scripts/classify-host-permission-blocker.py"
CLASSIFIER_TEST="$ROOT/Scripts/test-classify-host-permission-blocker.py"
[ -x "$CLASSIFIER" ]
[ -x "$CLASSIFIER_TEST" ]
grep -F 'classify-host-permission-blocker.py' "$SMOKE" >/dev/null
uses="$(grep -cF 'classify-host-permission-blocker.py' "$SMOKE")"
[ "$uses" -ge 1 ]

# Every wait_for_text failure must print which marker it was waiting for and
# name a log file to read, and the script must not be able to exit silently
# under set -e: a diagnostic function called from every failure branch, plus
# an ERR trap as a backstop, are both required.
diagnosis_calls="$(grep -cF 'fail_with_diagnosis' "$SMOKE")"
[ "$diagnosis_calls" -ge 6 ]
grep -E 'trap [a-zA-Z_]+ ERR' "$SMOKE" >/dev/null

if grep -Ei 'SensoriumCanvasExerciser|screencapture|zip|unzip|sudo|system_profiler' "$SMOKE" >/dev/null; then
  echo 'Workspace input smoke must use the product viewer/workspace without diagnostic capture, archives, or privilege escalation.' >&2
  exit 1
fi

printf 'PASS: real local workspace input smoke harness contract\n'
