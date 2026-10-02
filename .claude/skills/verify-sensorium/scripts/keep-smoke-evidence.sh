#!/bin/sh
# Copies an opt-in smoke's state directory out of .build before the next run
# of that smoke deletes it, redacting addresses, and proves nothing it started
# is still running.
#
#   .claude/skills/verify-sensorium/scripts/keep-smoke-evidence.sh <smoke> <label>
#
# <smoke> is the middle of the script name: host-screen, video,
# workspace-input, resize or focus-release. Copies
# .build/real-local-<smoke>-smoke/*.log, *.json and *.jsonl into
# Artifacts/verify/<UTC timestamp>-<label>/<smoke>/. Exit 1 if a process
# built from this repository is still alive afterwards.
set -u

[ $# -eq 2 ] || { echo "usage: keep-smoke-evidence.sh <smoke> <label>" >&2; exit 2; }
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
STATE="$ROOT/.build/real-local-$1-smoke"
[ -d "$STATE" ] || { echo "no state at $STATE" >&2; exit 2; }
EVIDENCE="$ROOT/Artifacts/verify/$(date -u +%Y%m%dT%H%M%SZ)-$2/$1"
mkdir -p "$EVIDENCE"
# The probe announces itself by this machine's own name, so that name is
# redacted along with addresses and DNS names.
for file in "$STATE"/*.log "$STATE"/*.json "$STATE"/*.jsonl; do
  [ -f "$file" ] || continue
  python3 - "$file" "$(scutil --get ComputerName 2>/dev/null)" "$(scutil --get LocalHostName 2>/dev/null)" \
    > "$EVIDENCE/$(basename "$file")" <<'PY'
import re, sys
text = open(sys.argv[1], errors="replace").read()
for name in sorted(filter(None, sys.argv[2:]), key=len, reverse=True):
    text = text.replace(name, "<this-machine>")
text = re.sub(r"\d+\.\d+\.\d+\.\d+", "<addr>", text)
text = re.sub(r"[A-Za-z0-9.-]+\.(?:local|ts\.net)", "<name>", text)
sys.stdout.write(text)
PY
done
ls -1 "$EVIDENCE"

leftover="$(ps -axo pid=,etime=,command= | grep -F "$ROOT/" | grep -i sensorium | grep -v grep | grep -v keep-smoke-evidence)"
if [ -n "$leftover" ]; then
  echo "STILL RUNNING (stop only the pid this run started, with kill -TERM):"
  printf '%s\n' "$leftover" | sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<addr>/g'
  echo "$EVIDENCE"
  exit 1
fi
echo "no repo-built Sensorium process running"
echo "$EVIDENCE"
