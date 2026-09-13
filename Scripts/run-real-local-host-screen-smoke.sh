#!/bin/sh
# Real single-machine host-screen smoke: the host streams one of this machine's own
# displays to a normal Sensorium viewer window, and the viewer's pointer and
# keyboard really move the cursor and type into a window standing on that
# display. The opt-in macOS integration test for host-screen mode, and the
# sibling of run-real-local-workspace-input-smoke.sh, which does the same for a
# session canvas.
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

stop_host() {
  app_process="$HOST_APP/Contents/MacOS/SensoriumHost"
  child_pids="$(pgrep -f "$app_process.* 7783" || true)"
  if [ -n "$child_pids" ]; then
    kill -TERM $child_pids 2>/dev/null || true
  fi
  if [ -n "$HOST_PID" ]; then
    kill -TERM "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
    HOST_PID=""
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
test -d "$HOST_APP" && test -x "$HOST_APP/Contents/MacOS/SensoriumHost" && test -x "$PROBE"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME"

swift Scripts/display_inventory.swift > "$STATE/display-inventory-pre.json"
python3 Scripts/check-display-active.py "$STATE/display-inventory-pre.json" || exit 3

/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args pair "$ADDRESS" 7783 --transport tcp-local-verification &
HOST_PID=$!
wait_for_text 'Pairing code:' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Pairing code:' in host log"
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" pair "$ADDRESS" 7783 "$CODE" > "$PROBE_LOG" 2>&1
wait_for_text 'host_screen_probe_paired=yes' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'host_screen_probe_paired=yes' in probe log"
stop_host

# Stands in for the arming ceremony a person performs in the host app's own
# interface, against this test HOME alone.
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" arm "$ARMING_FILE" >> "$PROBE_LOG" 2>&1 \
  || fail_with_diagnosis "the probe could not write the host's arming record"
test -f "$ARMING_FILE" || fail_with_diagnosis "no arming record was written at $ARMING_FILE"

set +e
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" wait-idle "$IDLE_WAIT_SECONDS" >> "$PROBE_LOG" 2>&1
idle_status=$?
set -e
if [ "$idle_status" = 3 ]; then
  blocked "$(tail -n 1 "$PROBE_LOG")"
fi
[ "$idle_status" = 0 ] || fail_with_diagnosis "the probe could not read this machine's local-input idle time"

: > "$HOST_LOG"
/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args serve "$ADDRESS" 7783 --transport tcp-local-verification &
HOST_PID=$!
wait_for_text 'Sensorium host bound' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Sensorium host bound' in host log"
if ! env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" enter "$ADDRESS" 7783 >> "$PROBE_LOG" 2>&1; then
  fail_with_diagnosis "the probe's 'enter' step failed"
fi

wait_for_text 'host screen started for' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'host screen started for' in host log"
wait_for_text 'host-screen capture started' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'host-screen capture started' in host log"
wait_for_text 'host_screen_frames=' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'host_screen_frames=' in probe log"
python3 -c 'import re,sys; text=open("'"$PROBE_LOG"'", errors="replace").read(); match=re.search(r"host_screen_frames=(\d+)", text); count=int(match.group(1)) if match else 0; print(f"host_screen_frames={count}"); moved="pointer_moved=yes" in text; typed="text_typed=yes" in text; print("pointer_moved=yes" if moved else "pointer_moved=no"); print("text_typed=yes" if typed else "text_typed=no"); sys.exit(0 if count > 0 and moved and typed else 1)' \
  || fail_with_diagnosis "the host screen was not streamed, or the viewer's pointer and keys did not reach it"

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
