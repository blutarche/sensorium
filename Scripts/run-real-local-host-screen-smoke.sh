#!/bin/sh
# Real single-machine host-screen smoke: the host streams one of this machine's own
# displays to a normal Sensorium viewer window, and the viewer's pointer and
# keyboard really move the cursor and type into a window standing on that
# display. The opt-in macOS integration test for host-screen mode, and the
# sibling of run-real-local-workspace-input-smoke.sh, which does the same for a
# session canvas.
#
# It also proves motion-time resolution on that display. The probe stands a
# large window of dense scrollable content on it, notes the size of the frames
# it decodes while the picture is still, scrolls the window through the viewer
# for a second and a half, then watches for three more seconds. The pass
# condition is smaller frames while the scroll ran, full-size frames again
# within one second of the last scroll event, and no smaller frame after that.
# A stream too small to have a motion size reports skipped-no-motion-size,
# which is not a failure.
#
# Every process this starts is pointed at a throwaway state directory under
# .build. `HOME` alone does not do that: Foundation reads the home directory
# from the password database, so `NSHomeDirectory()` ignores it, and a rig that
# set only `HOME` would read and write the real
# ~/Library/Application Support/Sensorium -- including this machine's real
# arming record. `CFFIXED_USER_HOME` is the one CoreFoundation honours.
#
# Arming is the one part no automated rig can perform the way a person does:
# it is host-local by construction and no wire message can create it
# (docs/host-screen-design.md §2.1). The probe writes the host's own arming file directly, through the
# host's own store, inside the throwaway HOME below -- never a real one.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="$ROOT/.build/real-local-host-screen-smoke"
HOST_HOME="$STATE/host"
CLIENT_HOME="$STATE/client"
ARMING_FILE="$HOST_HOME/Library/Application Support/Sensorium/host-screen-arming.json"
HOST_LOG="$STATE/host.log"
PROBE_LOG="$STATE/probe.log"
TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
PACKAGE="$ROOT/Scripts/package-apps.sh"
HOST_APP="$ROOT/Artifacts/Sensorium/Sensorium Host.app"
PROBE="$ROOT/.build/arm64-apple-macosx/release/SensoriumLocalHostScreenProbe"
CLASSIFIER="$ROOT/Scripts/classify-host-permission-blocker.py"
# How long to wait for this machine to be left alone. The host asks the person at
# it before sharing a screen when somebody has used it in the last few minutes
# (docs/host-screen-design.md §6.2), and nobody can answer that prompt on their behalf, so this rig
# waits the rule out instead of leaving a prompt on a real screen.
IDLE_WAIT_SECONDS=900
HOST_PID=""
LAUNCHER_PID=""
HOST_EXECUTABLE="$HOST_APP/Contents/MacOS/SensoriumHost"

validate_host_executable() {
  python3 - "$1" "$2" <<'PYPATH'
from pathlib import Path
import sys
root = Path(sys.argv[1]).resolve()
expected = root / "Artifacts/Sensorium/Sensorium Host.app"
app = Path(sys.argv[2]).resolve()
executable = (app / "Contents/MacOS/SensoriumHost").resolve()
if app != expected or executable != expected / "Contents/MacOS/SensoriumHost":
    raise SystemExit("FAIL: host executable must be the fixed repository test bundle, without escaping symlinks")
print(executable)
PYPATH
}

require_verification_port_available() {
  if lsof -nP -a -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "FAIL: verification port $1 already has a listener" >&2
    return 1
  else
    listener_status=$?
    if [ "$listener_status" -ne 1 ]; then
      echo "FAIL: could not check verification port $1" >&2
      return 1
    fi
  fi
}

resolve_host_listener_pid() {
  listener_port="$1"
  expected_executable="$2"
  listener_pids="$(lsof -nP -a -iTCP:"$listener_port" -sTCP:LISTEN -t 2>/dev/null | sort -u)"
  case "$listener_pids" in
    ""|*[!0-9]*) echo "FAIL: expected one test-host listener on port $listener_port" >&2; return 1 ;;
  esac
  actual_executable="$(ps -p "$listener_pids" -o comm=)"
  if [ "$actual_executable" != "$expected_executable" ]; then
    echo "FAIL: verification listener is not the repository test host" >&2
    return 1
  fi
  printf '%s\n' "$listener_pids"
}

stop_host() {
  if [ -z "$HOST_PID" ] && [ -n "$LAUNCHER_PID" ]; then
    HOST_PID="$(resolve_host_listener_pid 7783 "$HOST_EXECUTABLE")" || {
      echo "FAIL: cannot identify the launched test host; leaving its launcher running for safe cleanup" >&2
      return 1
    }
  fi
  if [ -n "$HOST_PID" ]; then
    actual_executable="$(ps -p "$HOST_PID" -o comm= 2>/dev/null || true)"
    if [ "$actual_executable" = "$HOST_EXECUTABLE" ]; then
      kill -TERM "$HOST_PID" 2>/dev/null || {
        echo "FAIL: could not stop the identified test host" >&2
        return 1
      }
    elif [ -n "$actual_executable" ]; then
      echo "FAIL: test-host PID changed executable; leaving it and the launcher running" >&2
      return 1
    fi
    HOST_PID=""
  fi
  if [ -n "$LAUNCHER_PID" ]; then
    wait "$LAUNCHER_PID" 2>/dev/null || true
    LAUNCHER_PID=""
  fi
}

cleanup() { stop_host; }
trap cleanup EXIT HUP INT TERM

# Backstop for `set -e`: any command failure this script has not already
# turned into an explicit diagnostic still prints one here before the shell
# exits, instead of exiting silently.
report_unexpected_failure() {
  status=$?
  echo "FAIL: run-real-local-host-screen-smoke.sh exited unexpectedly (status $status)" >&2
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $PROBE_LOG" >&2
}
trap report_unexpected_failure ERR

# An intentional BLOCKED exit is not an unexpected failure, so it leaves no
# ERR trap behind to print a second, contradictory diagnostic after it.
blocked() {
  trap - ERR
  for line in "$@"; do
    echo "$line" >&2
  done
  exit 3
}

wait_for_text() {
  needle="$1"
  file="$2"
  seconds="$3"
  count=0
  while [ "$count" -lt "$seconds" ]; do
    if [ -f "$file" ] && python3 -c 'import sys; raise SystemExit(0 if sys.argv[1] in open(sys.argv[2], errors="replace").read() else 1)' "$needle" "$file"; then
      return 0
    fi
    sleep 1
    count=$((count + 1))
  done
  return 1
}

contains_text() {
  [ -f "$2" ] && python3 -c 'import sys; raise SystemExit(0 if sys.argv[1] in open(sys.argv[2], errors="replace").read() else 1)' "$1" "$2"
}

# Every failure path goes through here, so a missing permission or a person at
# this machine is always reported as the specific thing it is, never as a bare
# non-zero exit.
fail_with_diagnosis() {
  context="$1"
  # docs/host-screen-design.md §6.2: this is a person at this machine being asked and not agreeing, or
  # not answering. It is the rule working, not a defect.
  if contains_text 'host-screen-presence-check-required' "$PROBE_LOG"; then
    blocked 'BLOCKED: someone is using this machine, so the host asked them before sharing a screen and did not get a yes.' \
      '  Leave this machine alone for five minutes and run this again.'
  fi
  if contains_text 'host-screen-not-allowed' "$PROBE_LOG"; then
    echo "FAIL: the host refused the armed display for this machine -- read $ARMING_FILE" >&2
    exit 1
  fi
  missing=""
  if [ -f "$HOST_LOG" ]; then
    missing="$(python3 "$CLASSIFIER" "$HOST_LOG" 2>/dev/null || true)"
  fi
  has_accessibility=0
  has_screen_recording=0
  case "$missing" in
    *Accessibility*) has_accessibility=1 ;;
  esac
  case "$missing" in
    *"Screen Recording"*) has_screen_recording=1 ;;
  esac
  if [ "$has_accessibility" = 1 ] && [ "$has_screen_recording" = 1 ]; then
    blocked 'BLOCKED: packaged host requires user-granted Accessibility and Screen Recording before host-screen control can run.'
  elif [ "$has_accessibility" = 1 ]; then
    blocked 'BLOCKED: packaged host requires user-granted Accessibility before host-screen control can run.'
  elif [ "$has_screen_recording" = 1 ]; then
    blocked 'BLOCKED: packaged host requires user-granted Screen Recording before host-screen control can run.'
  fi
  echo "FAIL: $context" >&2
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $PROBE_LOG" >&2
  exit 1
}

cd "$ROOT"
test -x "$TAILSCALE"
"$PACKAGE" >/dev/null
swift build -c release --product SensoriumLocalHostScreenProbe >/dev/null
test -d "$HOST_APP" && test -x "$HOST_EXECUTABLE" && test -x "$PROBE"
HOST_EXECUTABLE="$(validate_host_executable "$ROOT" "$HOST_APP")" || fail_with_diagnosis "the host executable was not the fixed repository test bundle"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME"

swift Scripts/display_inventory.swift > "$STATE/display-inventory-pre.json"
python3 Scripts/check-display-active.py "$STATE/display-inventory-pre.json" || exit 3

require_verification_port_available 7783 || fail_with_diagnosis "verification port 7783 was not vacant before test-host launch"
/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args pair "$ADDRESS" 7783 --transport tcp-local-verification &
LAUNCHER_PID=$!
wait_for_text 'Pairing code:' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Pairing code:' in host log"
HOST_PID="$(resolve_host_listener_pid 7783 "$HOST_EXECUTABLE")" || fail_with_diagnosis "could not identify the paired test host"
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" pair "$ADDRESS" 7783 "$CODE" > "$PROBE_LOG" 2>&1
wait_for_text 'host_screen_probe_paired=yes' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'host_screen_probe_paired=yes' in probe log"
stop_host

# Stands in for the arming ceremony a person performs in the host app's own
# interface, against this test HOME alone.
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" arm "$ARMING_FILE" >> "$PROBE_LOG" 2>&1 \
  || fail_with_diagnosis "the probe could not write the host's arming record"
test -f "$ARMING_FILE" || fail_with_diagnosis "no arming record was written at $ARMING_FILE"

idle_status=0
if env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" wait-idle "$IDLE_WAIT_SECONDS" >> "$PROBE_LOG" 2>&1; then
  idle_status=0
else
  idle_status=$?
fi
if [ "$idle_status" = 3 ]; then
  blocked "$(tail -n 1 "$PROBE_LOG")"
fi
[ "$idle_status" = 0 ] || fail_with_diagnosis "the probe could not read this machine's local-input idle time"

: > "$HOST_LOG"
require_verification_port_available 7783 || fail_with_diagnosis "verification port 7783 was not vacant before test-host launch"
/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args serve "$ADDRESS" 7783 --transport tcp-local-verification &
LAUNCHER_PID=$!
wait_for_text 'Sensorium host bound' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Sensorium host bound' in host log"
HOST_PID="$(resolve_host_listener_pid 7783 "$HOST_EXECUTABLE")" || fail_with_diagnosis "could not identify the serving test host"
if ! env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" enter "$ADDRESS" 7783 >> "$PROBE_LOG" 2>&1; then
  fail_with_diagnosis "the probe's 'enter' step failed"
fi

wait_for_text 'host screen started for' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'host screen started for' in host log"
wait_for_text 'host-screen capture started' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'host-screen capture started' in host log"
wait_for_text 'host_screen_frames=' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'host_screen_frames=' in probe log"
python3 -c 'import re,sys; text=open("'"$PROBE_LOG"'", errors="replace").read(); match=re.search(r"host_screen_frames=(\d+)", text); count=int(match.group(1)) if match else 0; print(f"host_screen_frames={count}"); moved="pointer_moved=yes" in text; typed="text_typed=yes" in text; print("pointer_moved=yes" if moved else "pointer_moved=no"); print("text_typed=yes" if typed else "text_typed=no"); sys.exit(0 if count > 0 and moved and typed else 1)' \
  || fail_with_diagnosis "the host screen was not streamed, or the viewer's pointer and keys did not reach it"

# Motion-time resolution: smaller frames while the viewer scrolls, the full size
# again soon after it stops, and the full size for as long as nothing moves. Each
# way it can go wrong gets its own message, so a picture that never shrank is
# never reported as one that never recovered. A stream under the motion
# threshold has no motion size, which is not a failure.
wait_for_text 'motion_check=' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'motion_check=' in probe log"
motion_value() {
  python3 -c 'import re,sys; match=re.search(sys.argv[1] + r"=(\S+)", open(sys.argv[2], errors="replace").read()); print(match.group(1) if match else "none")' "$1" "$PROBE_LOG"
}
motion_check="$(motion_value motion_check)"
motion_full_size="$(motion_value motion_full_size)"
motion_scroll_size="$(motion_value motion_scroll_size)"
motion_settled_after_ms="$(motion_value motion_settled_after_ms)"
motion_still_stays_full="$(motion_value motion_still_stays_full)"
printf 'motion_full_size=%s\nmotion_scroll_size=%s\nmotion_settled_after_ms=%s\nmotion_still_stays_full=%s\nmotion_check=%s\n' \
  "$motion_full_size" "$motion_scroll_size" "$motion_settled_after_ms" "$motion_still_stays_full" "$motion_check"
case "$motion_check" in
  pass | skipped-no-motion-size) ;;
  fail)
    if [ "$motion_scroll_size" = "$motion_full_size" ]; then
      fail_with_diagnosis "the host kept sending full-size frames while the viewer scrolled (motion_scroll_size=$motion_scroll_size)"
    elif [ "$motion_settled_after_ms" = none ]; then
      fail_with_diagnosis "the picture never returned to full size after the scroll stopped (motion_full_size=$motion_full_size, motion_scroll_size=$motion_scroll_size)"
    elif [ "$motion_still_stays_full" = no ]; then
      fail_with_diagnosis "the picture dropped below full size again after settling, with nothing moving (motion_settled_after_ms=$motion_settled_after_ms)"
    elif [ "$motion_settled_after_ms" -le 1000 ]; then
      # StreamMotionProof allows one second to recover the full size.
      fail_with_diagnosis "the scroll did not produce the configured motion resolution (motion_scroll_size=$motion_scroll_size)"
    fi
    fail_with_diagnosis "the picture returned to full size too long after the scroll stopped (motion_settled_after_ms=$motion_settled_after_ms)"
    ;;
  *) fail_with_diagnosis "the probe printed no motion verdict (motion_check=$motion_check)" ;;
esac

# The viewer-driven display-mode round trip against the real
# CoreGraphicsHostScreenModeController: a mode change requested mid-session,
# applied without interrupting the picture, and the mode this machine had before
# it always put back -- the one outcome this rig may never leave behind on a
# real display.
wait_for_text 'mode_restored=' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'mode_restored=' in probe log"
python3 -c 'import re,sys
text = open("'"$PROBE_LOG"'", errors="replace").read()
def find(pattern, default):
    match = re.search(pattern, text)
    return match.group(1) if match else default
mode_before = find(r"mode_before=(\S+)", "unknown")
mode_requested = find(r"mode_requested=(\S+)", "none")
mode_applied = find(r"mode_applied=(\S+)", "no")
mode_restored = find(r"mode_restored=(\S+)", "no")
mode_restored_by = find(r"mode_restored_by=(\S+)", "probe")
print(f"mode_before={mode_before}")
print(f"mode_requested={mode_requested}")
print(f"mode_applied={mode_applied}")
print(f"mode_restored={mode_restored}")
print(f"mode_restored_by={mode_restored_by}")
sys.exit(0 if mode_applied != "no" and mode_restored != "no" else 1)' \
  || fail_with_diagnosis "the host-screen display mode change did not apply cleanly, or the display was not restored to what it was on before"

stop_host
swift Scripts/display_inventory.swift > "$STATE/display-inventory-post.json"
python3 Scripts/compare-display-inventory.py "$STATE/display-inventory-pre.json" "$STATE/display-inventory-post.json" \
  || fail_with_diagnosis "the display inventory changed during teardown"
printf 'PASS: real local host screen smoke\n'
