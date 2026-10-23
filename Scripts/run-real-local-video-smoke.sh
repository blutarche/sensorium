#!/bin/sh
# Real single-machine media smoke: authenticates a throwaway viewer/host pair, captures
# only the session-owned canvas, requires the product workspace to render the
# first visible frame, and proves that it is decoded and presented before cleanup.
# HOST_APP selects an existing signed test fixture; otherwise the current apps
# are packaged before the test. Launch Services supplies the app identity.
#
# Every process this starts is pointed at a throwaway state directory under
# .build. `HOME` alone does not do that: Foundation reads the home directory
# from the password database, so the application-support directory ignores it,
# and a rig that set only `HOME` would read and write the real
# ~/Library/Application Support/Sensorium, including pairing records an
# installed host trusts. `CFFIXED_USER_HOME` is the one CoreFoundation honours.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="$ROOT/.build/real-local-video-smoke"
PORT=7782
HOST_HOME="$STATE/host"
CLIENT_HOME="$STATE/client"
HOST_LOG="$STATE/host.log"
CLIENT_LOG="$STATE/client.log"
HOST_TRACE="$STATE/host-trace.jsonl"
TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
PACKAGE="$ROOT/Scripts/package-apps.sh"
PACKAGED_HOST_APP="$ROOT/Artifacts/Sensorium/Sensorium Host.app"
HOST_APP="${HOST_APP:-$PACKAGED_HOST_APP}"
HOST="$HOST_APP/Contents/MacOS/SensoriumHost"
PROBE="$ROOT/.build/arm64-apple-macosx/release/SensoriumLocalWorkspaceInputProbe"
HOST_PID=""
LAUNCHER_PID=""
CLIENT_PID=""
SESSION_STARTED=0

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
    HOST_PID="$(resolve_host_listener_pid "$PORT" "$HOST")" || {
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

cleanup() {
  if [ -n "$CLIENT_PID" ]; then
    kill -INT "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
  if [ -n "$HOST_PID" ] || [ -n "$LAUNCHER_PID" ]; then
    if [ "$SESSION_STARTED" = 1 ] && ! wait_for_canvas_cleanup; then
      echo "FAIL: session display was not released; leaving the test host running for safe cleanup. Host log: $HOST_LOG" >&2
      return
    fi
    stop_host
  fi
}
trap cleanup EXIT HUP INT TERM

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

fail_with_diagnosis() {
  missing="$(python3 "$ROOT/Scripts/classify-host-permission-blocker.py" "$HOST_LOG" 2>/dev/null || true)"
  failure_status=1
  if [ -n "$missing" ]; then
    echo "BLOCKED: $missing" >&2
    failure_status=3
  else
    echo "FAIL: $1" >&2
  fi
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $CLIENT_LOG" >&2
  exit "$failure_status"
}

wait_for_canvas_cleanup() {
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    if swift "$ROOT/Scripts/display_inventory.swift" > "$STATE/display-inventory-post.json" \
      && python3 "$ROOT/Scripts/compare-display-inventory.py" "$STATE/display-inventory-pre.json" "$STATE/display-inventory-post.json" >/dev/null 2>&1; then
      SESSION_STARTED=0
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  return 1
}

HOST_APP="$(validate_host_app "$HOST_APP")" || exit 1
HOST="$HOST_APP/Contents/MacOS/SensoriumHost"
cd "$ROOT"
if lsof -nP -a -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "FAIL: test port $PORT already has a listener" >&2
  exit 1
fi
test -x "$TAILSCALE"
if [ "$HOST_APP" = "$PACKAGED_HOST_APP" ]; then
  "$PACKAGE" >/dev/null
fi
HOST_APP="$(validate_host_app "$HOST_APP")" || exit 1
HOST="$HOST_APP/Contents/MacOS/SensoriumHost"
swift build -c release --product SensoriumLocalWorkspaceInputProbe >/dev/null
test -x "$HOST" && test -x "$PROBE"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME"

swift Scripts/display_inventory.swift > "$STATE/display-inventory-pre.json"
python3 Scripts/check-display-active.py "$STATE/display-inventory-pre.json" || exit 3

/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args pair "$ADDRESS" "$PORT" --transport tcp-local-verification &
LAUNCHER_PID=$!
wait_for_pattern 'Pairing code:' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for pairing code"
HOST_PID="$(resolve_host_listener_pid "$PORT" "$HOST")" || fail_with_diagnosis "could not identify the pairing host"
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" pair "$ADDRESS" "$PORT" "$CODE" > "$CLIENT_LOG" 2>&1 \
  || fail_with_diagnosis "the probe could not pair"
grep -q 'local_input_probe_paired=yes' "$CLIENT_LOG" || fail_with_diagnosis "pairing completed without an approval marker"

stop_host
: > "$HOST_LOG"
/usr/bin/open -n -W --stdout "$HOST_LOG" --stderr "$HOST_LOG" --env HOME="$HOST_HOME" --env CFFIXED_USER_HOME="$HOST_HOME" "$HOST_APP" --args serve "$ADDRESS" "$PORT" --transport tcp-local-verification --trace "$HOST_TRACE" &
LAUNCHER_PID=$!
wait_for_pattern 'Sensorium host bound' "$HOST_LOG" 10 || fail_with_diagnosis "timed out waiting for host listener"
HOST_PID="$(resolve_host_listener_pid "$PORT" "$HOST")" || fail_with_diagnosis "could not identify the streaming host"

SESSION_STARTED=1
env HOME="$CLIENT_HOME" CFFIXED_USER_HOME="$CLIENT_HOME" "$PROBE" enter-video "$ADDRESS" "$PORT" >> "$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!
if ! wait "$CLIENT_PID"; then
  CLIENT_PID=""
  fail_with_diagnosis "the video probe failed before decoding and presenting the workspace"
fi
CLIENT_PID=""
wait_for_pattern 'workspace started on session canvas' "$HOST_LOG" 10 || fail_with_diagnosis "no workspace started on the session canvas"
wait_for_pattern 'capture started on session canvas' "$HOST_LOG" 10 || fail_with_diagnosis "capture did not start on the session canvas"
grep -q 'video_probe_disconnected=yes' "$CLIENT_LOG" || fail_with_diagnosis "the video probe did not disconnect cleanly"
python3 -c 'import re,sys; text=open(sys.argv[1], errors="replace").read(); count=lambda key: int((re.search(key + r"=(\d+)", text) or [None, "0"])[1]); decoded=count("decoded_frames"); presented=count("presented_frames"); print(f"decoded_frames={decoded}"); print(f"presented_frames={presented}"); print("workspace_frame_presented=yes" if decoded > 0 and presented > 0 else "workspace_frame_presented=no"); sys.exit(0 if decoded > 0 and presented > 0 else 1)' "$CLIENT_LOG" \
  || fail_with_diagnosis "the probe did not decode and present a workspace frame"
wait_for_canvas_cleanup || fail_with_diagnosis "the session display was not released after disconnect"

# Evidence only: the host's own capture/encode/send breakdown and dropped-
# frame count, reported next to the viewer's decode/present numbers above.
# Never a PASS/FAIL condition for this smoke.
wait_for_pattern 'host stage latency' "$HOST_LOG" 10 || true
if [ -f "$HOST_TRACE" ]; then
  python3 -c '
import json
try:
    rows = [json.loads(line) for line in open("'"$HOST_TRACE"'", encoding="utf-8") if line.strip()]
except FileNotFoundError:
    rows = []
by_stage = {row["stage"]: row for row in rows}
for stage in ("capture", "encode", "send"):
    row = by_stage.get(stage)
    if row:
        count = row["count"]
        p50 = row["p50Nanoseconds"] / 1e6
        p95 = row["p95Nanoseconds"] / 1e6
        print(f"host_{stage}_count={count}")
        print(f"host_{stage}_p50_ms={p50:.1f}")
        print(f"host_{stage}_p95_ms={p95:.1f}")
    else:
        print(f"host_{stage}_count=0 (no samples)")
'
else
  echo "host_trace_missing=yes"
fi
if grep -q 'host stage latency' "$HOST_LOG"; then
  grep 'host stage latency' "$HOST_LOG" | tail -1
else
  echo "host stage latency: no session-end summary observed"
fi

stop_host
swift Scripts/display_inventory.swift > "$STATE/display-inventory-post.json"
python3 Scripts/compare-display-inventory.py "$STATE/display-inventory-pre.json" "$STATE/display-inventory-post.json"
printf 'PASS: real local video smoke\n'
