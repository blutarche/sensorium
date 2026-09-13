#!/bin/sh
# Real single-machine stream-resolution rebuild smoke: drives a live scale change on
# an authenticated session with `SensoriumLocalWorkspaceInputProbe enter-resize`
# and proves the host's real VTCompressionSession/SCStream rebuild and the
# client's real VideoToolboxDecoder resolution swap both actually recover, in
# both directions, rather than only compiling.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATE="$ROOT/.build/real-local-resize-smoke"
HOST_HOME="$STATE/host"
CLIENT_HOME="$STATE/client"
HOST_LOG="$STATE/host.log"
PROBE_LOG="$STATE/probe.log"
TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
HOST="$ROOT/.build/arm64-apple-macosx/release/sensoriumd"
PROBE="$ROOT/.build/arm64-apple-macosx/release/SensoriumLocalWorkspaceInputProbe"
PORT=7787
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
  echo "FAIL: run-real-local-resize-smoke.sh exited unexpectedly (status $status)" >&2
  echo "  host log: $HOST_LOG" >&2
  echo "  probe log: $PROBE_LOG" >&2
}
trap report_unexpected_failure ERR

fail() {
  echo "FAIL: $1" >&2
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
test -x "$TAILSCALE" || fail "Tailscale.app is not installed at $TAILSCALE"
swift build -c release --product sensoriumd --product SensoriumLocalWorkspaceInputProbe >/dev/null
test -x "$HOST" && test -x "$PROBE" || fail "release build did not produce sensoriumd or the probe binary"
ADDRESS="$($TAILSCALE ip -4)"
test -n "$ADDRESS" || fail "tailscale ip -4 returned no address"

rm -rf "$STATE"
mkdir -p "$HOST_HOME" "$CLIENT_HOME"

swift Scripts/display_inventory.swift > "$STATE/display-inventory-pre.json"
python3 Scripts/check-display-active.py "$STATE/display-inventory-pre.json" || exit 3

env HOME="$HOST_HOME" "$HOST" pair "$ADDRESS" "$PORT" --transport tcp-local-verification > "$HOST_LOG" 2>&1 &
HOST_PID=$!
wait_for_pattern 'Pairing code:' "$HOST_LOG" 10 || fail "timed out waiting for 'Pairing code:' in host log"
CODE="$(python3 -c 'import re; print(re.search(r"Pairing code: (\d{6})", open("'"$HOST_LOG"'").read()).group(1))')"
env HOME="$CLIENT_HOME" "$PROBE" pair "$ADDRESS" "$PORT" "$CODE" > "$PROBE_LOG" 2>&1 \
  || fail "the probe's 'pair' step failed"
grep -q 'local_input_probe_paired=yes' "$PROBE_LOG" || fail "probe did not report local_input_probe_paired=yes"

kill -TERM "$HOST_PID" 2>/dev/null || true
wait "$HOST_PID" 2>/dev/null || true
HOST_PID=""
: > "$HOST_LOG"
env HOME="$HOST_HOME" "$HOST" serve "$ADDRESS" "$PORT" --transport tcp-local-verification > "$HOST_LOG" 2>&1 &
HOST_PID=$!
wait_for_pattern 'Sensorium host bound' "$HOST_LOG" 10 || fail "timed out waiting for 'Sensorium host bound' in host log"

env HOME="$CLIENT_HOME" SENSORIUM_ALLOW_RESIZE_SMOKE=1 "$PROBE" enter-resize "$ADDRESS" "$PORT" >> "$PROBE_LOG" 2>&1 &
PROBE_PID=$!

wait_for_pattern 'workspace started on session canvas' "$HOST_LOG" 20 \
  || fail "timed out waiting for 'workspace started on session canvas' in host log"
wait_for_pattern 'capture started on session canvas' "$HOST_LOG" 20 \
  || fail "timed out waiting for 'capture started on session canvas' in host log"
wait_for_pattern 'resize_smoke_complete=yes' "$PROBE_LOG" 45 \
  || fail "timed out waiting for 'resize_smoke_complete=yes' in probe log"

wait "$PROBE_PID"
PROBE_STATUS=$?
PROBE_PID=""
[ "$PROBE_STATUS" -eq 0 ] || fail "probe exited $PROBE_STATUS instead of completing the resize smoke"

# Each stage must decode frames at the dimensions it requested; a stream
# that died after the change is what this smoke exists to catch. scaled_up
# is checked only for being strictly larger and landing on a
# StreamScalePolicy quantum step, because what the encoder can hold at 2.0x
# varies by machine (see EncodeSustainabilityPolicy).
CANVAS_WIDTH="1920" CANVAS_HEIGHT="1200" python3 -c '
import os, re, sys

text = open("'"$PROBE_LOG"'", errors="replace").read()

def field(name):
    match = re.search(rf"^{name}=(\d+)$", text, re.MULTILINE)
    if not match:
        print(f"FAIL: missing {name} in probe log", file=sys.stderr)
        sys.exit(1)
    return int(match.group(1))

canvas_width = int(os.environ["CANVAS_WIDTH"])
canvas_height = int(os.environ["CANVAS_HEIGHT"])
# Mirrors Sources/SensoriumCore/StreamScalePolicy.swift: 1.0...2.0 in 0.25 steps.
quantum = 0.25
minimum_scale = 1.0
maximum_scale = 2.0
steps = round((maximum_scale - minimum_scale) / quantum)
quantized_scales = [round(minimum_scale + i * quantum, 2) for i in range(steps + 1)]

ok = True

def report(stage):
    decoded = field(f"resize_stage_{stage}_decoded")
    width = field(f"resize_stage_{stage}_width")
    height = field(f"resize_stage_{stage}_height")
    print(f"resize_stage_{stage}_decoded={decoded}")
    print(f"resize_stage_{stage}_width={width}")
    print(f"resize_stage_{stage}_height={height}")
    return decoded, width, height

for stage in ("baseline", "scaled_down"):
    decoded, width, height = report(stage)
    if decoded < 1:
        print(f"FAIL: stage {stage} decoded no frames — the stream died instead of recovering", file=sys.stderr)
        ok = False
    if (width, height) != (canvas_width, canvas_height):
        print(f"FAIL: stage {stage} decoded {width}x{height}, expected {canvas_width}x{canvas_height}", file=sys.stderr)
        ok = False

decoded, width, height = report("scaled_up")
if decoded < 1:
    print("FAIL: stage scaled_up decoded no frames — the stream died instead of recovering", file=sys.stderr)
    ok = False
if not (width > canvas_width and height > canvas_height):
    print(f"FAIL: stage scaled_up decoded {width}x{height}, expected strictly larger than baseline {canvas_width}x{canvas_height} in both dimensions", file=sys.stderr)
    ok = False
else:
    matched_scale = next(
        (scale for scale in quantized_scales if (round(canvas_width * scale), round(canvas_height * scale)) == (width, height)),
        None,
    )
    if matched_scale is None:
        print(f"FAIL: stage scaled_up decoded {width}x{height}, which is not {canvas_width}x{canvas_height} scaled by any StreamScalePolicy quantum step in {quantized_scales}", file=sys.stderr)
        ok = False
    else:
        print(f"resize_stage_scaled_up_scale={matched_scale:.2f}x")

sys.exit(0 if ok else 1)
' || fail "decoded frame count or dimensions did not match at one or more resize stages"

# The 0.35s debounce must collapse each requested change into exactly one
# settled rebuild; every extra "stream scale now" line must be accounted
# for by one "measured unsustainable" backoff.
python3 -c '
import re, sys

host_text = open("'"$HOST_LOG"'", errors="replace").read()
lines = [line.rstrip() for line in host_text.splitlines() if "stream scale now" in line]
backoffs = [line.rstrip() for line in host_text.splitlines() if "measured unsustainable" in line]
for line in lines:
    print(line)
for line in backoffs:
    print(line)

up_settled = [line for line in lines if "2.00x" in line and "encoding 3840x2400" in line]
down_settled = [line for line in lines if "1.00x" in line and "encoding 1920x1200" in line]

ok = True
if len(up_settled) != 1:
    print(f"FAIL: expected exactly one initial settled rebuild at the requested 2.00x, found {len(up_settled)}", file=sys.stderr)
    ok = False
if len(down_settled) != 1:
    print(f"FAIL: expected exactly one settled rebuild at 1.00x, found {len(down_settled)} — 1.00x is always sustainable and must never trigger a backoff", file=sys.stderr)
    ok = False
if len(lines) != 2 + len(backoffs):
    print(f"FAIL: {len(lines)} \"stream scale now\" lines do not reconcile with 2 debounced settles + {len(backoffs)} sustainability backoffs", file=sys.stderr)
    ok = False

if backoffs:
    match = re.search(r"backing off to (\d+\.\d+)x", backoffs[-1])
    target = match.group(1) + "x" if match else "unknown"
    print(f"resize_stage_scaled_up_sustainability=backed-off-to-{target}")
else:
    print("resize_stage_scaled_up_sustainability=held-at-2.00x")

sys.exit(0 if ok else 1)
' || fail "host did not log the expected settled reconfigurations and sustainability outcome for the requested scale changes"

kill -TERM "$HOST_PID"
wait "$HOST_PID" 2>/dev/null || true
HOST_PID=""
swift Scripts/display_inventory.swift > "$STATE/display-inventory-post.json"
python3 Scripts/compare-display-inventory.py "$STATE/display-inventory-pre.json" "$STATE/display-inventory-post.json" \
  || fail "the display inventory changed during the session"
printf 'PASS: real local resize smoke\n'
