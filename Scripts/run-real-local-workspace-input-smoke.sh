#!/bin/sh
# Real same-Mac viewer/input smoke: a normal Sensorium viewer window presents the
# product workspace, routes a key through the client surface router, and proves
# the host injected it into the editable workspace on the owned canvas.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="$ROOT/.build/real-local-workspace-input-smoke"
HOST_HOME="$STATE/host"
CLIENT_HOME="$STATE/client"
HOST_LOG="$STATE/host.log"
PROBE_LOG="$STATE/probe.log"
TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
PACKAGE="$ROOT/Scripts/package-apps.sh"
HOST_APP="$ROOT/Artifacts/Sensorium/Sensorium Host.app"
PROBE="$ROOT/.build/arm64-apple-macosx/release/SensoriumLocalWorkspaceInputProbe"
CLASSIFIER="$ROOT/Scripts/classify-host-permission-blocker.py"
FOCUS_CLASSIFIER="$ROOT/Scripts/classify-workspace-focus-blocker.py"
HOST_PID=""

stop_host() {
  app_process="$HOST_APP/Contents/MacOS/SensoriumHost"
  child_pids="$(pgrep -f "$app_process.* 7781" || true)"
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
  echo "FAIL: run-real-local-workspace-input-smoke.sh exited unexpectedly (status $status)" >&2
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $PROBE_LOG" >&2
}
trap report_unexpected_failure ERR

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

# Classifies the host log for the Accessibility/Screen Recording authorization
# markers on ANY failure path (not only a failed probe `enter`), and prints a
# specific BLOCKED line naming exactly what is missing. Falls through to a
# generic diagnostic — never a silent exit — when the failure was not a
# permission boundary.
fail_with_diagnosis() {
  context="$1"
  focus_reason=""
  if [ -f "$PROBE_LOG" ]; then
    focus_reason="$(python3 "$FOCUS_CLASSIFIER" "$PROBE_LOG" 2>/dev/null || true)"
  fi
  if [ -n "$focus_reason" ]; then
    echo "BLOCKED: $focus_reason" >&2
    exit 3
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
    echo 'BLOCKED: packaged host requires user-granted Accessibility and Screen Recording before local viewer/control acceptance can run.' >&2
    exit 3
  elif [ "$has_accessibility" = 1 ]; then
    echo 'BLOCKED: packaged host requires user-granted Accessibility before local viewer/control acceptance can run.' >&2
    exit 3
  elif [ "$has_screen_recording" = 1 ]; then
    echo 'BLOCKED: packaged host requires user-granted Screen Recording before local viewer/control acceptance can run.' >&2
    exit 3
  fi
  echo "FAIL: $context" >&2
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $PROBE_LOG" >&2
  exit 1
}

cd "$ROOT"
test -x "$TAILSCALE"
"$PACKAGE" >/dev/null
swift build -c release --product SensoriumLocalWorkspaceInputProbe >/dev/null
test -d "$HOST_APP" && test -x "$HOST_APP/Contents/MacOS/SensoriumHost" && test -x "$PROBE"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME"

swift Scripts/display_inventory.swift > "$STATE/display-inventory-pre.json"
python3 Scripts/check-display-active.py "$STATE/display-inventory-pre.json" || exit 3

/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" "$HOST_APP" --args pair "$ADDRESS" 7781 --transport tcp-local-verification &
HOST_PID=$!
wait_for_text 'Pairing code:' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Pairing code:' in host log"
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" "$PROBE" pair "$ADDRESS" 7781 "$CODE" > "$PROBE_LOG" 2>&1
wait_for_text 'local_input_probe_paired=yes' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'local_input_probe_paired=yes' in probe log"
stop_host
: > "$HOST_LOG"
/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" "$HOST_APP" --args serve "$ADDRESS" 7781 --transport tcp-local-verification &
HOST_PID=$!
wait_for_text 'Sensorium host bound' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Sensorium host bound' in host log"
if ! env HOME="$CLIENT_HOME" "$PROBE" enter "$ADDRESS" 7781 >> "$PROBE_LOG" 2>&1; then
  fail_with_diagnosis "the probe's 'enter' step failed"
fi

wait_for_text 'workspace started on session canvas' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'workspace started on session canvas' in host log"
wait_for_text 'capture started on session canvas' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'capture started on session canvas' in host log"
wait_for_text 'Sensorium workspace: text input observed' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Sensorium workspace: text input observed' in host log"
wait_for_text 'viewer_presented_frames=' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'viewer_presented_frames=' in probe log"
wait_for_text 'workspace_input_sent=yes' "$PROBE_LOG" 5 || fail_with_diagnosis "timed out waiting for 'workspace_input_sent=yes' in probe log"
python3 -c 'import re,sys; text=open("'"$PROBE_LOG"'", errors="replace").read(); match=re.search(r"viewer_presented_frames=(\d+)", text); count=int(match.group(1)) if match else 0; print(f"viewer_presented_frames={count}"); print("workspace_input_sent=yes" if count > 0 and "workspace_input_sent=yes" in text else "workspace_input_sent=no"); sys.exit(0 if count > 0 and "workspace_input_sent=yes" in text else 1)' || fail_with_diagnosis "no presented frames or no sent-input evidence in probe log"

stop_host
swift Scripts/display_inventory.swift > "$STATE/display-inventory-post.json"
python3 Scripts/compare-display-inventory.py "$STATE/display-inventory-pre.json" "$STATE/display-inventory-post.json" \
  || fail_with_diagnosis "the display inventory changed during teardown"
printf 'PASS: real local workspace input smoke\n'
