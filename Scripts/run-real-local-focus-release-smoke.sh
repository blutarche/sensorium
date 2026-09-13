#!/bin/sh
# Real single-machine stuck-input smoke: proves a real held modifier key and mouse
# button are really released on the real canvas when the viewer loses focus.
# It holds input down without a matching up, triggers the exact
# `NSWindow.didResignKeyNotification`/`NSApplication.didResignActiveNotification`
# path `ClientCanvasWindowController` observes (not the release method
# directly), and asserts on the real OS-level `CGEventSource` key/button
# state — not any in-process bookkeeping — via
# `SensoriumLocalWorkspaceInputProbe enter-focus-release`.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="$ROOT/.build/real-local-focus-release-smoke"
HOST_HOME="$STATE/host"
CLIENT_HOME="$STATE/client"
HOST_LOG="$STATE/host.log"
PROBE_LOG="$STATE/probe.log"
TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
HOST="$ROOT/.build/arm64-apple-macosx/release/sensoriumd"
PROBE="$ROOT/.build/arm64-apple-macosx/release/SensoriumLocalWorkspaceInputProbe"
CLASSIFIER="$ROOT/Scripts/classify-host-permission-blocker.py"
FOCUS_CLASSIFIER="$ROOT/Scripts/classify-workspace-focus-blocker.py"
PORT=7788
HOST_PID=""
PROBE_PID=""

cleanup() {
  if [ -n "$PROBE_PID" ]; then
    kill -TERM "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
  fi
  if [ -n "$HOST_PID" ]; then
    kill -TERM "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

# Backstop for `set -e`: any command failure not already turned into an
# explicit diagnostic below still prints one here before the shell exits,
# instead of exiting silently.
report_unexpected_failure() {
  status=$?
  echo "FAIL: run-real-local-focus-release-smoke.sh exited unexpectedly (status $status)" >&2
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $PROBE_LOG" >&2
}
trap report_unexpected_failure ERR

# Classifies the host log for the Accessibility authorization marker on any
# failure path. Input injection specifically requires Accessibility (video
# does not), so this smoke checks for it even though it uses the raw
# SwiftPM binary rather than the packaged app.
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
  case "$missing" in
    *Accessibility*)
      echo 'BLOCKED: this host requires user-granted Accessibility before a held key/button release can be verified.' >&2
      exit 3
      ;;
  esac
  echo "FAIL: $context" >&2
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $PROBE_LOG" >&2
  exit 1
}

wait_for_pattern() {
  pattern="$1"
  file="$2"
  seconds="$3"
  count=0
  while [ "$count" -lt "$seconds" ]; do
    if [ -f "$file" ] && grep -q "$pattern" "$file"; then
      return 0
    fi
    sleep 1
    count=$((count + 1))
  done
  return 1
}

cd "$ROOT"
test -x "$TAILSCALE" || fail_with_diagnosis "Tailscale.app is not installed at $TAILSCALE"
swift build -c release --product sensoriumd --product SensoriumLocalWorkspaceInputProbe >/dev/null
test -x "$HOST" && test -x "$PROBE" || fail_with_diagnosis "release build did not produce sensoriumd or the probe binary"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS" || fail_with_diagnosis "tailscale ip -4 returned no address"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME"

swift Scripts/display_inventory.swift > "$STATE/display-inventory-pre.json"
python3 Scripts/check-display-active.py "$STATE/display-inventory-pre.json" || exit 3

env HOME="$HOST_HOME" "$HOST" pair "$ADDRESS" "$PORT" --transport tcp-local-verification > "$HOST_LOG" 2>&1 &
HOST_PID=$!
wait_for_pattern 'Pairing code:' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Pairing code:' in host log"
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" "$PROBE" pair "$ADDRESS" "$PORT" "$CODE" > "$PROBE_LOG" 2>&1 \
  || fail_with_diagnosis "the probe's 'pair' step failed"
grep -q 'local_input_probe_paired=yes' "$PROBE_LOG" || fail_with_diagnosis "probe did not report local_input_probe_paired=yes"

kill -TERM "$HOST_PID" 2>/dev/null || true
wait "$HOST_PID" 2>/dev/null || true
HOST_PID=""
: > "$HOST_LOG"
env HOME="$HOST_HOME" "$HOST" serve "$ADDRESS" "$PORT" --transport tcp-local-verification > "$HOST_LOG" 2>&1 &
HOST_PID=$!
wait_for_pattern 'Sensorium host bound' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for 'Sensorium host bound' in host log"

env HOME="$CLIENT_HOME" SENSORIUM_ALLOW_FOCUS_RELEASE_SMOKE=1 "$PROBE" enter-focus-release "$ADDRESS" "$PORT" >> "$PROBE_LOG" 2>&1 &
PROBE_PID=$!

wait_for_pattern 'workspace started on session canvas' "$HOST_LOG" 20 \
  || fail_with_diagnosis "timed out waiting for 'workspace started on session canvas' in host log"
wait_for_pattern 'capture started on session canvas' "$HOST_LOG" 20 \
  || fail_with_diagnosis "timed out waiting for 'capture started on session canvas' in host log"
wait_for_pattern 'focus_release_smoke_complete=yes' "$PROBE_LOG" 30 \
  || fail_with_diagnosis "timed out waiting for 'focus_release_smoke_complete=yes' in probe log"

wait "$PROBE_PID"
PROBE_STATUS=$?
PROBE_PID=""
[ "$PROBE_STATUS" -eq 0 ] || fail_with_diagnosis "probe exited $PROBE_STATUS instead of completing the focus-release smoke"

# The probe's own markers are the real evidence: the held key/button were
# actually observed physically down (proving the down side reached real OS
# input, not just the wire), and after the exact AppKit focus-loss
# notifications were posted, both were observed physically up and the
# aggregate modifier flags do not report Shift either.
grep -qF 'focus_release_held_shift_down=true' "$PROBE_LOG" \
  || fail_with_diagnosis "probe log never showed the held modifier key as physically down"
grep -qF 'focus_release_held_left_button_down=true' "$PROBE_LOG" \
  || fail_with_diagnosis "probe log never showed the held mouse button as physically down"
grep -qF 'focus_release_notifications_posted=yes' "$PROBE_LOG" \
  || fail_with_diagnosis "probe log never confirmed the real AppKit focus-loss notifications were posted"
grep -qF 'focus_release_after_shift_down=false' "$PROBE_LOG" \
  || fail_with_diagnosis "probe log never showed the modifier key released after focus loss"
grep -qF 'focus_release_after_left_button_down=false' "$PROBE_LOG" \
  || fail_with_diagnosis "probe log never showed the mouse button released after focus loss"
grep -qF 'focus_release_shift_flag_still_set=false' "$PROBE_LOG" \
  || fail_with_diagnosis "probe log never confirmed the aggregate modifier flags settled after release"

kill -TERM "$HOST_PID"
wait "$HOST_PID" 2>/dev/null || true
HOST_PID=""
swift Scripts/display_inventory.swift > "$STATE/display-inventory-post.json"
python3 Scripts/compare-display-inventory.py "$STATE/display-inventory-pre.json" "$STATE/display-inventory-post.json" \
  || fail_with_diagnosis "the display inventory changed during the session"
printf 'PASS: real local focus release smoke\n'
