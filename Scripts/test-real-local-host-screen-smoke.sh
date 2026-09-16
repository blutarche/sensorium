#!/bin/sh
# Contract for the real host-screen smoke.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE="$ROOT/Scripts/run-real-local-host-screen-smoke.sh"

[ -x "$SMOKE" ]
grep -F 'SensoriumLocalHostScreenProbe' "$SMOKE" >/dev/null
grep -F 'Scripts/package-apps.sh' "$SMOKE" >/dev/null
grep -F '/usr/bin/open -n -W' "$SMOKE" >/dev/null

# The three facts this smoke exists to establish, none of which the viewer
# could report without the host really capturing and really injecting: frames
# of a real display arrived, the cursor on that display moved where the viewer
# asked, and a key typed into a window standing on it.
grep -F 'host_screen_frames=' "$SMOKE" >/dev/null
grep -F 'pointer_moved=yes' "$SMOKE" >/dev/null
grep -F 'text_typed=yes' "$SMOKE" >/dev/null
grep -F 'host screen started for' "$SMOKE" >/dev/null
grep -F 'host-screen capture started' "$SMOKE" >/dev/null

# Sensorium must never create, remove, or alter a physical display. The
# inventory taken either side of the run is what proves this one did not.
grep -F 'compare-display-inventory.py' "$SMOKE" >/dev/null
grep -F 'display-inventory-pre.json' "$SMOKE" >/dev/null
grep -F 'display-inventory-post.json' "$SMOKE" >/dev/null
grep -F 'check-display-active.py "$STATE/display-inventory-pre.json" || exit 3' "$SMOKE" >/dev/null

# Arming is host-local and no wire message may create it, so the rig writes the
# host's own file -- and it must only ever write one inside the throwaway HOME
# it makes under .build, never a real Application Support directory.
grep -F 'ARMING_FILE="$HOST_HOME/Library/Application Support/Sensorium/host-screen-arming.json"' "$SMOKE" >/dev/null
grep -F 'HOST_HOME="$STATE/host"' "$SMOKE" >/dev/null
# `HOME` alone does not redirect Foundation's application-support directory:
# it reads the home directory from the password database. Without
# CFFIXED_USER_HOME on every process this rig starts, the host would read and
# write this machine's real arming record instead of the throwaway one.
cffixed_uses="$(grep -cF 'CFFIXED_USER_HOME=' "$SMOKE")"
[ "$cffixed_uses" -ge 6 ]
grep -F 'CFFIXED_USER_HOME="$HOST_HOME"' "$SMOKE" >/dev/null
grep -F 'CFFIXED_USER_HOME="$CLIENT_HOME"' "$SMOKE" >/dev/null
grep -F 'STATE="$ROOT/.build/real-local-host-screen-smoke"' "$SMOKE" >/dev/null

# The viewer-driven display-mode round trip against the real
# CoreGraphicsHostScreenModeController must be exercised end to end, and a
# mode change that did not apply or a display left unrestored must fail the
# whole run -- the one outcome this rig may never leave behind.
grep -F 'mode_before=' "$SMOKE" >/dev/null
grep -F 'mode_requested=' "$SMOKE" >/dev/null
grep -F 'mode_applied=' "$SMOKE" >/dev/null
grep -F 'mode_restored=' "$SMOKE" >/dev/null
grep -F 'mode_restored_by=' "$SMOKE" >/dev/null
grep -F 'wait_for_text '"'"'mode_restored='"'"'' "$SMOKE" >/dev/null
grep -F 'mode_applied != "no" and mode_restored != "no"' "$SMOKE" >/dev/null

# A person at this machine is asked before their screen is shared, and nobody can
# answer that on their behalf: the rig waits for the machine to be left alone
# and reports BLOCKED rather than leaving an unanswerable prompt on a real
# screen or reading a refusal as a defect.
grep -F 'wait-idle' "$SMOKE" >/dev/null
grep -F 'host-screen-presence-check-required' "$SMOKE" >/dev/null
grep -F 'BLOCKED: someone is using this machine' "$SMOKE" >/dev/null

# Missing Accessibility and missing Screen Recording must each be reportable on
# their own, classified from the host log by the fixture-tested classifier
# rather than re-implemented inline.
CLASSIFIER="$ROOT/Scripts/classify-host-permission-blocker.py"
CLASSIFIER_TEST="$ROOT/Scripts/test-classify-host-permission-blocker.py"
[ -x "$CLASSIFIER" ]
[ -x "$CLASSIFIER_TEST" ]
grep -F 'classify-host-permission-blocker.py' "$SMOKE" >/dev/null
grep -F 'BLOCKED: packaged host requires user-granted Accessibility before host-screen control can run.' "$SMOKE" >/dev/null
grep -F 'BLOCKED: packaged host requires user-granted Screen Recording before host-screen control can run.' "$SMOKE" >/dev/null
grep -F 'BLOCKED: packaged host requires user-granted Accessibility and Screen Recording before host-screen control can run.' "$SMOKE" >/dev/null

# Every wait_for_text failure must name what it was waiting for and a log to
# read, and the script must not be able to exit silently under set -e.
diagnosis_calls="$(grep -cF 'fail_with_diagnosis' "$SMOKE")"
[ "$diagnosis_calls" -ge 6 ]
grep -E 'trap [a-zA-Z_]+ ERR' "$SMOKE" >/dev/null

if grep -Ei 'SensoriumCanvasExerciser|screencapture|displayplacer|zip|unzip|sudo|system_profiler|defaults |launchctl' "$SMOKE" >/dev/null; then
  echo 'Host screen smoke must use the product host and viewer without diagnostic capture, display tools, or privilege escalation.' >&2
  exit 1
fi

printf 'PASS: real local host screen smoke harness contract\n'
