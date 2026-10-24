#!/bin/sh
# Real single-machine lock-screen typing smoke: proves a viewer's keystrokes
# reach the host's lock screen password field, which is how a locked host is
# unlocked. The viewer connects to the host screen, locks the machine with the
# lock shortcut if it is not locked already, types five letters (never Return)
# with no click first, and compares the lower centre of the streamed frame
# before and after. It empties the field before typing and again after. It
# then asks the host for a different display mode through the viewer's own
# mode request, checks the picture resumes, disconnects, and checks the display
# is back on the mode it had. The pass condition is the field changing, the
# field being left empty, the mode change applying (a display offering one mode
# reports skipped-single-mode, which is not a failure), the mode being
# restored, and the display inventory being unchanged once the host stops.
#
# This locks the machine and leaves it locked, with its password field empty.
# It therefore refuses to run unless SENSORIUM_ALLOW_LOCK=1 is set.
#
# HOST_APP selects a repository .build test fixture; the packaged repository
# build is the default. Installed hosts and paths outside the repo are refused.
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
HOST_PID=""
LAUNCHER_PID=""

if [ "${SENSORIUM_ALLOW_LOCK:-}" != 1 ]; then
  echo 'REFUSED: this smoke locks the machine and leaves it locked.' >&2
  echo '  Set SENSORIUM_ALLOW_LOCK=1 to run it.' >&2
  exit 2
fi

validate_host_app() {
  python3 - "$ROOT" "$1" <<'PYPATH'
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
app = Path(sys.argv[2]).resolve()
packaged = root / "Artifacts/Sensorium/Sensorium Host.app"
if app != packaged and not (app.is_relative_to(root / ".build") and app.suffix == ".app"):
    raise SystemExit("FAIL: HOST_APP must be the repository package or a .build test fixture")
executable = (app / "Contents/MacOS/SensoriumHost").resolve()
if not executable.is_relative_to(app):
    raise SystemExit("FAIL: test-host executable resolves outside its repository bundle")
print(app)
PYPATH
}

require_host_port_free() {
  listener_pids="$(lsof -nP -a -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -n "$listener_pids" ]; then
    echo "FAIL: test-host port $1 is already occupied; no host was launched or signalled" >&2
    return 1
  fi
}

resolve_host_listener_pid() {
  listener_port="$1"
  expected_executable="$2"
  listener_pids="$(lsof -nP -a -iTCP:"$listener_port" -sTCP:LISTEN -t 2>/dev/null | sort -u)"
  case "$listener_pids" in
    ""|0|*[!0-9]*) echo "FAIL: expected one test-host listener on port $listener_port" >&2; return 1 ;;
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
    HOST_PID="$(resolve_host_listener_pid 7783 "$HOST")" || {
      echo "FAIL: cannot identify the launched test host; leaving its launcher running for safe cleanup" >&2
      return 1
    }
  fi
  if [ -n "$HOST_PID" ]; then
    actual_executable="$(ps -p "$HOST_PID" -o comm= 2>/dev/null || true)"
    if [ "$actual_executable" = "$HOST" ]; then
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
  echo "  This machine may be left locked, and its password field may not be empty." >&2
  exit 1
}

HOST_APP="$(validate_host_app "$HOST_APP")" || exit 1
HOST="$HOST_APP/Contents/MacOS/SensoriumHost"
cd "$ROOT"
test -x "$TAILSCALE"
if [ "$HOST_APP" = "$PACKAGED_HOST_APP" ]; then
  "$PACKAGE" >/dev/null
fi
swift build -c release --product SensoriumLocalHostScreenProbe >/dev/null
HOST_APP="$(validate_host_app "$HOST_APP")" || exit 1
HOST="$HOST_APP/Contents/MacOS/SensoriumHost"
test -d "$HOST_APP" && test -x "$HOST_APP/Contents/MacOS/SensoriumHost" && test -x "$PROBE"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME" "$SHOT_DIR"

# The displays as they stand before anything runs, to compare once the host
# stops. A sleeping display can report a stale arrangement: a monitor that only
# joins on wake changes the set and the modes. So the displays are woken first
# (a user-activity assertion, the same public power management the host uses)
# and the baseline is the first of two identical readings a few seconds apart.
settled_display_inventory() {
  caffeinate -u -t 3
  previous="$STATE/display-inventory-settle.json"
  swift Scripts/display_inventory.swift > "$previous"
  tries=0
  while [ "$tries" -lt 10 ]; do
    sleep 3
    swift Scripts/display_inventory.swift > "$1"
    if cmp -s "$previous" "$1"; then
      return 0
    fi
    cp "$1" "$previous"
    tries=$((tries + 1))
  done
  fail "the display arrangement did not settle within 30 seconds"
}
settled_display_inventory "$STATE/display-inventory-pre.json"

require_host_port_free 7783 || fail "test-host port is already occupied"
/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args pair "$ADDRESS" 7783 --transport tcp-local-verification &
LAUNCHER_PID=$!
wait_for_text 'Pairing code:' "$HOST_LOG" 10 || fail "timed out waiting for 'Pairing code:' in host log"
HOST_PID="$(resolve_host_listener_pid 7783 "$HOST")" || fail "could not identify the pairing test host"
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" pair "$ADDRESS" 7783 "$CODE" > "$PROBE_LOG" 2>&1
wait_for_text 'host_screen_probe_paired=yes' "$PROBE_LOG" 5 || fail "timed out waiting for 'host_screen_probe_paired=yes' in probe log"
stop_host

# Stands in for the arming ceremony a person performs in the host app's own
# interface, against this throwaway HOME alone.
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" arm "$ARMING_FILE" >> "$PROBE_LOG" 2>&1 \
  || fail "the probe could not write the host's arming record"
test -f "$ARMING_FILE" || fail "no arming record was written at $ARMING_FILE"

# No idle wait: asking first is off in a fresh HOME, so the host never prompts
# the person at the machine before sharing this screen.

: > "$HOST_LOG"
require_host_port_free 7783 || fail "test-host port is already occupied"
/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args serve "$ADDRESS" 7783 --transport tcp-local-verification &
LAUNCHER_PID=$!
wait_for_text 'Sensorium host bound' "$HOST_LOG" 10 || fail "timed out waiting for 'Sensorium host bound' in host log"
HOST_PID="$(resolve_host_listener_pid 7783 "$HOST")" || fail "could not identify the streaming test host"

set +e
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" lock-typing "$ADDRESS" 7783 "$SHOT_DIR" >> "$PROBE_LOG" 2>&1
probe_status=$?
set -e

stop_host
swift Scripts/display_inventory.swift > "$STATE/display-inventory-post.json"

# Mode failures are judged from the probe's own lines, and each gets its own
# message so a bad mode change is never reported as a typing failure.
mode_applied="$(python3 -c 'import re,sys; match=re.search(r"mode_applied=(\S+)", open(sys.argv[1], errors="replace").read()); print(match.group(1) if match else "no")' "$PROBE_LOG")"
mode_restored="$(python3 -c 'import re,sys; match=re.search(r"mode_restored=(\S+)", open(sys.argv[1], errors="replace").read()); print(match.group(1) if match else "no")' "$PROBE_LOG")"
# A display offering one mode has nothing to restore, so the probe prints no
# mode_restored line for it.
if [ "$mode_applied" = skipped-single-mode ] && ! contains_text 'mode_restored=' "$PROBE_LOG"; then
  mode_restored=skipped-single-mode
fi

if contains_text 'lock_typing_field_changed=yes' "$PROBE_LOG" && contains_text 'lock_typing_field_cleared=yes' "$PROBE_LOG" \
  && [ "$mode_applied" != no ] && [ "$mode_restored" != no ] && [ "$probe_status" = 0 ]; then
  python3 Scripts/compare-display-inventory.py "$STATE/display-inventory-pre.json" "$STATE/display-inventory-post.json" \
    || fail "the display inventory changed during teardown"
  trap - ERR
  printf 'PASS: real local lock typing smoke\n'
  echo "  screenshots: $SHOT_DIR"
  echo '  This machine is left locked, with its password field empty.'
  exit 0
fi
if contains_text 'lock_typing_field_changed=no' "$PROBE_LOG"; then
  fail "typing did not change the lock screen password field (compare the PNGs in $SHOT_DIR)"
fi
if contains_text 'lock_typing_field_cleared=no' "$PROBE_LOG"; then
  fail "the typed letters were not deleted from the lock screen password field (see lock-after-clearing.png in $SHOT_DIR)"
fi
if contains_text 'lock_typing_field_changed=yes' "$PROBE_LOG" && [ "$mode_applied" = no ]; then
  fail "the display mode change did not apply cleanly (mode_applied=$mode_applied)"
fi
if contains_text 'lock_typing_field_changed=yes' "$PROBE_LOG" && [ "$mode_restored" = no ]; then
  fail "the display was not restored to the mode it was on before (mode_restored=$mode_restored)"
fi
fail "the lock-typing probe stopped before it could judge the password field (status $probe_status)"
