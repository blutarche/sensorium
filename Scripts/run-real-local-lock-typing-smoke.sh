#!/bin/sh
# Real single-machine lock-screen typing smoke: proves a viewer's keystrokes
# reach the host's lock screen password field, which is how a locked host is
# unlocked. The viewer connects to the host screen, locks the machine with the
# lock shortcut if it is not locked already, types five letters (never Return)
# with no click first, and compares the lower centre of the streamed frame
# before and after. The field changing is the pass condition.
#
# This locks the machine and leaves it locked: the person at it unlocks it.
# It therefore refuses to run unless SENSORIUM_ALLOW_LOCK=1 is set.
#
# HOST_APP selects the host to test; the packaged build is the default. Set it
# to "/Applications/Sensorium Host.app" to test an installed copy.
#
# Every process this starts is pointed at a throwaway state directory under
# .build through CFFIXED_USER_HOME (`HOME` alone does not move Foundation's
# application-support directory). Arming is host-local and no wire message can
# create it, so the probe writes the host's own arming file inside that
# throwaway home, never a real one.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="$ROOT/.build/real-local-lock-typing-smoke"
HOST_HOME="$STATE/host"
CLIENT_HOME="$STATE/client"
SHOT_DIR="$STATE/shots"
ARMING_FILE="$HOST_HOME/Library/Application Support/Sensorium/host-screen-arming.json"
HOST_LOG="$STATE/host.log"
PROBE_LOG="$STATE/probe.log"
TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
PACKAGE="$ROOT/Scripts/package-apps.sh"
PACKAGED_HOST_APP="$ROOT/Artifacts/Sensorium/Sensorium Host.app"
HOST_APP="${HOST_APP:-$PACKAGED_HOST_APP}"
PROBE="$ROOT/.build/arm64-apple-macosx/release/SensoriumLocalHostScreenProbe"
# The host asks the person at the machine before sharing a screen when somebody
# used it recently, and nobody can answer for them, so this waits the rule out.
IDLE_WAIT_SECONDS=900
HOST_PID=""

if [ "${SENSORIUM_ALLOW_LOCK:-}" != 1 ]; then
  echo 'REFUSED: this smoke locks the machine and leaves it locked.' >&2
  echo '  Set SENSORIUM_ALLOW_LOCK=1 to run it.' >&2
  exit 2
fi

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

# Backstop for `set -e`: a command failure not already turned into an explicit
# diagnostic still prints one before the shell exits.
report_unexpected_failure() {
  status=$?
  echo "FAIL: run-real-local-lock-typing-smoke.sh exited unexpectedly (status $status)" >&2
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

contains_text() {
  [ -f "$2" ] && python3 -c 'import sys; raise SystemExit(0 if sys.argv[1] in open(sys.argv[2], errors="replace").read() else 1)' "$1" "$2"
}

fail() {
  trap - ERR
  echo "FAIL: $1" >&2
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $PROBE_LOG" >&2
  echo "  This machine may be locked; unlock it yourself." >&2
  exit 1
}

cd "$ROOT"
test -x "$TAILSCALE"
if [ "$HOST_APP" = "$PACKAGED_HOST_APP" ]; then
  "$PACKAGE" >/dev/null
fi
swift build -c release --product SensoriumLocalHostScreenProbe >/dev/null
test -d "$HOST_APP" && test -x "$HOST_APP/Contents/MacOS/SensoriumHost" && test -x "$PROBE"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME" "$SHOT_DIR"

/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args pair "$ADDRESS" 7783 --transport tcp-local-verification &
HOST_PID=$!
wait_for_text 'Pairing code:' "$HOST_LOG" 10 || fail "timed out waiting for 'Pairing code:' in host log"
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" pair "$ADDRESS" 7783 "$CODE" > "$PROBE_LOG" 2>&1
wait_for_text 'host_screen_probe_paired=yes' "$PROBE_LOG" 5 || fail "timed out waiting for 'host_screen_probe_paired=yes' in probe log"
stop_host

# Stands in for the arming ceremony a person performs in the host app's own
# interface, against this throwaway HOME alone.
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" arm "$ARMING_FILE" >> "$PROBE_LOG" 2>&1 \
  || fail "the probe could not write the host's arming record"
test -f "$ARMING_FILE" || fail "no arming record was written at $ARMING_FILE"

set +e
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" wait-idle "$IDLE_WAIT_SECONDS" >> "$PROBE_LOG" 2>&1
idle_status=$?
set -e
if [ "$idle_status" = 3 ]; then
  trap - ERR
  tail -n 1 "$PROBE_LOG" >&2
  exit 3
fi
[ "$idle_status" = 0 ] || fail "the probe could not read this machine's local-input idle time"

: > "$HOST_LOG"
/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args serve "$ADDRESS" 7783 --transport tcp-local-verification &
HOST_PID=$!
wait_for_text 'Sensorium host bound' "$HOST_LOG" 10 || fail "timed out waiting for 'Sensorium host bound' in host log"

set +e
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" lock-typing "$ADDRESS" 7783 "$SHOT_DIR" >> "$PROBE_LOG" 2>&1
probe_status=$?
set -e

stop_host
if contains_text 'lock_typing_field_changed=yes' "$PROBE_LOG" && [ "$probe_status" = 0 ]; then
  trap - ERR
  printf 'PASS: real local lock typing smoke\n'
  echo "  screenshots: $SHOT_DIR"
  echo '  This machine is left locked; unlock it yourself.'
  exit 0
fi
if contains_text 'lock_typing_field_changed=no' "$PROBE_LOG"; then
  fail "typing did not change the lock screen password field (compare the PNGs in $SHOT_DIR)"
fi
fail "the lock-typing probe stopped before it could judge the password field (status $probe_status)"
