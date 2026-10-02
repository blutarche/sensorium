#!/bin/sh
# Read-only health check before driving Sensorium for verification.
# Prints facts, changes nothing, starts nothing that outlives it.
#
#   .claude/skills/verify-sensorium/scripts/doctor.sh
#
# Exit 0: renders and loopback are safe to run.
# Exit 1: something blocks even those (no toolchain, not the repo).
# The last line always says whether an opt-in real-machine smoke may run.
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
cd "$ROOT" || exit 1
[ -f Package.swift ] && grep -q 'Sensorium' Package.swift || { echo "FAIL: $ROOT is not the Sensorium checkout"; exit 1; }

smoke_blockers=""
add_blocker() { smoke_blockers="${smoke_blockers}${smoke_blockers:+; }$1"; }
# Addresses never reach the transcript or an evidence file in clear.
redact() { sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<addr>/g; s/[A-Za-z0-9.-]+\.(local|ts\.net)/<name>/g'; }

echo "== build"
echo "commit: $(git rev-parse --short HEAD)$(git diff --quiet && git diff --cached --quiet || echo ' (dirty)')"
swift --version 2>/dev/null | head -1 || { echo "FAIL: no swift toolchain"; exit 1; }
release="$ROOT/.build/arm64-apple-macosx/release"
for product in Sensorium sensoriumd SensoriumLocalHostScreenProbe; do
  if [ -x "$release/$product" ]; then
    if [ -n "$(find Sources -name '*.swift' -newer "$release/$product" -print -quit)" ]; then
      echo "$product: built, OLDER than Sources (rebuild before a smoke)"
    else
      echo "$product: built, current"
    fi
  else
    echo "$product: not built"
  fi
done
host_app="$ROOT/Artifacts/Sensorium/Sensorium Host.app"
if [ -d "$host_app" ]; then
  echo "packaged host: present ($(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$host_app/Contents/MacOS/SensoriumHost"))"
else
  echo "packaged host: absent (host-screen smoke packages it itself)"
fi

echo "== processes"
# The installed apps belong to the owner. They are reported, never touched.
ps -axo pid=,etime=,command= | grep -i 'sensorium' | grep -v grep | grep -v 'doctor.sh' | while read -r pid etime command; do
  case "$command" in
    /Applications/*) origin="installed (owner's, never stop it)" ;;
    "$ROOT"/*) origin="REPO BUILD (stray unless a run in progress started it)" ;;
    *) origin="other" ;;
  esac
  echo "pid $pid  up $etime  $origin  $(printf '%s' "$command" | redact | cut -c1-140)"
done
for port in 7781 7782 7783 7787 7788; do
  if lsof -nP -iTCP:"$port" -iUDP:"$port" >/dev/null 2>&1; then
    echo "port $port: IN USE"
    add_blocker "port $port in use"
  fi
done
if lsof -nP -iUDP:7777 -iTCP:7777 >/dev/null 2>&1; then
  echo "port 7777: in use (the installed host's port; no verification run may bind it)"
fi

echo "== screen"
if ioreg -n Root -d1 -a 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
  echo "screen: LOCKED"
  add_blocker "screen locked (never unlock it; typing lands on the lock screen)"
else
  echo "screen: unlocked"
fi
inventory="$(swift Scripts/display_inventory.swift 2>/dev/null)"
if [ -n "$inventory" ]; then
  printf '%s' "$inventory" | python3 -c '
import json, sys
inv = json.load(sys.stdin)
print("displays: %d online (ids %s), %d active" % (
    len(inv["online"]), ",".join(str(d["id"]) for d in inv["online"]), len(inv["active"])))'
  printf '%s' "$inventory" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["active"] else 1)' \
    || add_blocker "no active display (asleep or locked)"
else
  echo "displays: inventory unavailable (run unsandboxed)"
  add_blocker "display inventory unavailable"
fi

echo "== network"
if [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
  if /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 >/dev/null 2>&1; then
    echo "tailnet address: present"
  else
    echo "tailnet address: none"
    add_blocker "no tailnet address"
  fi
else
  echo "tailscale CLI: absent"
  add_blocker "Tailscale not installed"
fi

echo "== owner's host-screen sessions"
# Outcome only: entries name real devices and displays, which never get printed.
log="$HOME/Library/Application Support/Sensorium/host-screen-sessions.log"
if [ -f "$log" ]; then
  python3 - "$log" <<'EOF'
import json, sys
try:
    entries = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("unreadable")
    sys.exit(0)
if not entries:
    print("none recorded")
    sys.exit(0)
last = max(entries, key=lambda e: e.get("startedAt", 0))
outcome = last.get("outcome") or {}
state = "stopped" if "stopped" in outcome else ("LIVE OR UNCLOSED: " + (",".join(outcome) or "no outcome"))
print("%d recorded; latest: %s" % (len(entries), state))
EOF
else
  echo "none"
fi

echo "== verdict"
echo "renders and loopback: OK to run"
if [ -n "$smoke_blockers" ]; then
  echo "real-machine smoke: NO ($smoke_blockers)"
else
  echo "real-machine smoke: preconditions met; still needs explicit approval for an opt-in integration test"
fi
