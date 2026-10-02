#!/bin/sh
# Runs the in-process host/viewer loopback (authenticated handshake, session
# lifecycle, input path, resize, recovery) and keeps its output as evidence.
#
#   .claude/skills/verify-sensorium/scripts/loopback.sh <label>
#
# In-memory transport and a fake display adapter: no socket, no permission,
# no display. Writes Artifacts/verify/<UTC timestamp>-<label>/loopback.log.
# Run it unsandboxed: sandboxed runners hang at 0% CPU instead of failing.
set -u

[ $# -eq 1 ] || { echo "usage: loopback.sh <label>" >&2; exit 2; }
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 1
EVIDENCE="$ROOT/Artifacts/verify/$(date -u +%Y%m%dT%H%M%SZ)-$1"
mkdir -p "$EVIDENCE"
git rev-parse HEAD > "$EVIDENCE/commit.txt"
Scripts/run-loopback-integration.sh > "$EVIDENCE/loopback.log" 2>&1
status=$?
echo "exit=$status" >> "$EVIDENCE/loopback.log"
grep -E '^(PASS|FAIL)' "$EVIDENCE/loopback.log"
echo "exit=$status"
echo "$EVIDENCE"
exit "$status"
