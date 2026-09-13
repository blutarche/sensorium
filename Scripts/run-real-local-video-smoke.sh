#!/bin/sh
# Real single-machine media smoke: authenticates a throwaway viewer/host pair, captures
# only the session-owned canvas, requires the product workspace to render the
# first visible frame, and proves that it is decoded and presented before cleanup.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="$ROOT/.build/real-local-video-smoke"
HOST_HOME="$STATE/host"
CLIENT_HOME="$STATE/client"
HOST_LOG="$STATE/host.log"
CLIENT_LOG="$STATE/client.log"
CLIENT_TRACE="$STATE/client-trace.jsonl"
HOST_TRACE="$STATE/host-trace.jsonl"
TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
HOST="$ROOT/.build/arm64-apple-macosx/release/sensoriumd"
CLIENT="$ROOT/.build/arm64-apple-macosx/release/Sensorium"
HOST_PID=""
CLIENT_PID=""

cleanup() {
  if [ -n "$CLIENT_PID" ]; then
    kill -INT "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
  if [ -n "$HOST_PID" ]; then
    kill -TERM "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
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

cd "$ROOT"
test -x "$TAILSCALE"
swift build -c release >/dev/null
test -x "$HOST" && test -x "$CLIENT"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME"

swift Scripts/display_inventory.swift > "$STATE/display-inventory-pre.json"
python3 Scripts/check-display-active.py "$STATE/display-inventory-pre.json" || exit 3

env HOME="$HOST_HOME" "$HOST" pair "$ADDRESS" 7777 --transport tcp-local-verification > "$HOST_LOG" 2>&1 &
HOST_PID=$!
wait_for_pattern 'Pairing code:' "$HOST_LOG" 10
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" "$CLIENT" pair "$ADDRESS" 7777 "$CODE" --transport tcp-local-verification > "$STATE/client-pair.log" 2>&1
grep -q 'Paired with' "$STATE/client-pair.log"

kill -TERM "$HOST_PID" 2>/dev/null || true
wait "$HOST_PID" 2>/dev/null || true
HOST_PID=""
: > "$HOST_LOG"
env HOME="$HOST_HOME" "$HOST" serve "$ADDRESS" 7777 --transport tcp-local-verification --trace "$HOST_TRACE" > "$HOST_LOG" 2>&1 &
HOST_PID=$!
wait_for_pattern 'Sensorium host bound' "$HOST_LOG" 10

env HOME="$CLIENT_HOME" "$CLIENT" enter --transport tcp-local-verification --trace "$CLIENT_TRACE" > "$CLIENT_LOG" 2>&1 &
CLIENT_PID=$!
wait_for_pattern 'workspace started on session canvas' "$HOST_LOG" 20
wait_for_pattern 'capture started on session canvas' "$HOST_LOG" 20
sleep 10

kill -INT "$CLIENT_PID"
wait "$CLIENT_PID" 2>/dev/null || true
CLIENT_PID=""
python3 -c 'import json, sys; rows=[json.loads(line) for line in open("'"$CLIENT_TRACE"'", encoding="utf-8") if line.strip()]; counts={row["stage"]: row["count"] for row in rows}; decoded=counts.get("decode", 0); presented=counts.get("present", 0); print(f"decoded_frames={decoded}"); print(f"presented_frames={presented}"); print("workspace_frame_presented=yes" if decoded >= 1 and presented >= 1 else "workspace_frame_presented=no"); sys.exit(0 if decoded >= 1 and presented >= 1 else 1)'

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

kill -TERM "$HOST_PID"
wait "$HOST_PID" 2>/dev/null || true
HOST_PID=""
swift Scripts/display_inventory.swift > "$STATE/display-inventory-post.json"
python3 Scripts/compare-display-inventory.py "$STATE/display-inventory-pre.json" "$STATE/display-inventory-post.json"
printf 'PASS: real local video smoke\n'
