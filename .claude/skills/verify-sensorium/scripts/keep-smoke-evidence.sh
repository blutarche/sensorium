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

leftover="$(python3 - "$ROOT" <<'PYPROCESSES'
from pathlib import Path
import subprocess
import sys

PRODUCTS = {
    "SensoriumHost", "sensoriumd", "Sensorium", "SensoriumViewerProbe",
    "SensoriumLocalWorkspaceInputProbe", "SensoriumLocalHostScreenProbe",
    "SensoriumBenchHost", "SensoriumCanvasExerciser", "SensoriumQuicProbe",
    "SensoriumVirtualDisplayPreflight",
}

def repo_product_processes(rows, root, cwd_for_pid):
    root = Path(root).resolve()
    allowed_roots = [root / ".build", root / "Artifacts"]
    matches = []
    for row in rows.splitlines():
        fields = row.strip().split(maxsplit=2)
        if len(fields) != 3 or not fields[0].isdigit():
            continue
        pid, elapsed, executable = fields
        path = Path(executable)
        if path.name not in PRODUCTS:
            continue
        if not path.is_absolute():
            if not path.parts or path.parts[0] not in {".build", "Artifacts"}:
                continue
            cwd = cwd_for_pid(pid)
            if not cwd:
                continue
            path = Path(cwd) / path
        if ".." in path.parts or not any(path.is_relative_to(parent) for parent in allowed_roots):
            continue
        path = path.resolve()
        if any(path.is_relative_to(parent) for parent in allowed_roots):
            matches.append(f"{pid} {elapsed} {path}")
    return matches

def process_cwd(pid):
    result = subprocess.run(["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
                            text=True, capture_output=True)
    return next((line[1:] for line in result.stdout.splitlines() if line.startswith("n")), None)

if __name__ == "__main__":
    rows = subprocess.check_output(["ps", "-ww", "-axo", "pid=,etime=,comm="], text=True)
    print("\n".join(repo_product_processes(rows, sys.argv[1], process_cwd)))
PYPROCESSES
)" || exit 1
if [ -n "$leftover" ]; then
  echo "STILL RUNNING (stop only the pid this run started, with kill -TERM):"
  printf '%s\n' "$leftover" | sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<addr>/g'
  echo "$EVIDENCE"
  exit 1
fi
echo "no repo-built Sensorium process running"
echo "$EVIDENCE"
