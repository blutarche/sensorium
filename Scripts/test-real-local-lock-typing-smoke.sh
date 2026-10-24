#!/bin/sh
# Contract for the real lock-screen typing smoke.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE="$ROOT/Scripts/run-real-local-lock-typing-smoke.sh"

[ -x "$SMOKE" ]
grep -F 'SensoriumLocalHostScreenProbe' "$SMOKE" >/dev/null
grep -F 'Scripts/package-apps.sh' "$SMOKE" >/dev/null
grep -F '/usr/bin/open -n -W' "$SMOKE" >/dev/null
grep -F 'lock-typing' "$SMOKE" >/dev/null
grep -F 'lock_typing_field_changed=yes' "$SMOKE" >/dev/null
grep -F 'PASS: real local lock typing smoke' "$SMOKE" >/dev/null

# The smoke locks the machine, so it must refuse to start without an explicit
# opt-in, and must do so before it builds or launches anything.
grep -F 'SENSORIUM_ALLOW_LOCK' "$SMOKE" >/dev/null
guard_line="$(grep -nF 'SENSORIUM_ALLOW_LOCK' "$SMOKE" | tail -n 1 | cut -d: -f1)"
first_build_line="$(grep -nF 'swift build' "$SMOKE" | head -n 1 | cut -d: -f1)"
[ "$guard_line" -lt "$first_build_line" ]
refusal_status=0
env -u SENSORIUM_ALLOW_LOCK "$SMOKE" >/dev/null 2>&1 || refusal_status=$?
if [ "$refusal_status" != 2 ]; then
  echo 'The lock typing smoke did not refuse to run without SENSORIUM_ALLOW_LOCK=1.' >&2
  exit 1
fi

# The host under test can be chosen, and the script says it leaves the machine locked.
grep -F 'HOST_APP="${HOST_APP:-' "$SMOKE" >/dev/null
grep -F 'left locked' "$SMOKE" >/dev/null
# It passes only when the probe left the password field empty.
grep -F 'lock_typing_field_cleared=yes' "$SMOKE" >/dev/null

# It also proves the viewer-driven display-mode round trip on the locked
# machine: the mode change applied (or the display offers only one mode), the
# display came back to the mode it had, and the display inventory is unchanged
# once the host is stopped.
grep -F 'mode_applied' "$SMOKE" >/dev/null
grep -F 'mode_restored' "$SMOKE" >/dev/null
# A sleeping display can report a stale arrangement, so the baseline is taken
# only once the displays are awake and two readings agree.
grep -F 'caffeinate -u' "$SMOKE" >/dev/null
grep -F 'settled_display_inventory "$STATE/display-inventory-pre.json"' "$SMOKE" >/dev/null
grep -F 'the display mode change did not apply' "$SMOKE" >/dev/null
grep -F 'the display was not restored to the mode it was on before' "$SMOKE" >/dev/null
grep -F 'Scripts/display_inventory.swift' "$SMOKE" >/dev/null
grep -F 'Scripts/compare-display-inventory.py' "$SMOKE" >/dev/null
grep -F 'the display inventory changed during teardown' "$SMOKE" >/dev/null
last_stop_line="$(grep -n '^stop_host$' "$SMOKE" | tail -n 1 | cut -d: -f1)"
post_inventory_line="$(grep -nF 'display-inventory-post.json' "$SMOKE" | head -n 1 | cut -d: -f1)"
[ "$last_stop_line" -lt "$post_inventory_line" ]

# Exercise only extracted shell functions against temporary paths and stubbed
# process inspection; none of these cases launches or signals a real process.
python3 - "$ROOT" "$SMOKE" <<'PYTEST'
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root, smoke = map(Path, sys.argv[1:])
source = smoke.read_text()
def definition(name):
    start = source.index(name + "() {")
    return source[start:source.index("\n}\n", start) + 3]

with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory)
    repository = fixture / "repository"
    packaged = repository / "Artifacts/Sensorium/Sensorium Host.app"
    signed = repository / ".build/signed/Test Host.app"
    outside = fixture / "external/Test Host.app"
    for app in (packaged, signed, outside):
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/SensoriumHost").touch()
    escaped = repository / ".build/Escaped.app"
    escaped.symlink_to(outside)
    executable_escape = repository / ".build/Executable Escape.app"
    (executable_escape / "Contents/MacOS").mkdir(parents=True)
    (executable_escape / "Contents/MacOS/SensoriumHost").symlink_to(outside / "Contents/MacOS/SensoriumHost")
    for app, allowed in ((packaged, True), (signed, True), (outside, False),
                         (Path("/Applications/Sensorium Host.app"), False),
                         (escaped, False), (executable_escape, False)):
        result = subprocess.run(
            ["sh", "-c", 'ROOT="$1"\n' + definition("validate_host_app") + '\nvalidate_host_app "$2"',
             "path-fixture", str(repository), str(app)], text=True, capture_output=True,
        )
        assert (result.returncode == 0) == allowed, (app, result)
        if allowed:
            assert result.stdout.strip() == str(app.resolve()), result.stdout

    stubs = '''lsof() { printf '%s\\n' "$FAKE_PIDS"; }
ps() { printf '%s\\n' "$FAKE_EXECUTABLE"; }
'''
    expected = str(signed / "Contents/MacOS/SensoriumHost")
    for pids, executable, allowed in (("123", expected, True), ("", expected, False),
                                       ("0", expected, False), ("123\n456", expected, False),
                                       ("123", str(outside), False)):
        result = subprocess.run(
            ["sh", "-c", stubs + definition("resolve_host_listener_pid") + '\nresolve_host_listener_pid 7783 "$1"',
             "listener-fixture", expected],
            env={**os.environ, "FAKE_PIDS": pids, "FAKE_EXECUTABLE": executable}, text=True, capture_output=True,
        )
        assert (result.returncode == 0) == allowed, (pids, executable, result)
        if allowed:
            assert result.stdout.strip() == "123", result.stdout

    for pids, allowed in (("", True), ("123", False), ("123\n456", False)):
        result = subprocess.run(
            ["sh", "-c", stubs + definition("require_host_port_free") + '\nrequire_host_port_free 7783',
             "vacancy-fixture"],
            env={**os.environ, "FAKE_PIDS": pids}, text=True, capture_output=True,
        )
        assert (result.returncode == 0) == allowed, (pids, result)

    for host_pid, pids, actual, expected_code, expected_actions in (
        ("123", "123", expected, 0, ["signal -TERM 123", "wait 456"]),
        ("123", "123", str(outside), 1, []),
        ("", "123", expected, 0, ["signal -TERM 123", "wait 456"]),
        ("", "123\n456", expected, 1, []),
        ("", "", expected, 1, []),
    ):
        result = subprocess.run(
            ["sh", "-c", stubs + '''kill() { printf 'signal %s\\n' "$*"; }
wait() { printf 'wait %s\\n' "$*"; }
HOST_PID="$FAKE_HOST_PID"
LAUNCHER_PID=456
HOST="$1"
''' + definition("resolve_host_listener_pid") + definition("stop_host")
             + '\nstop_host || exit $?\nstop_host', "stop-fixture", expected],
            env={**os.environ, "FAKE_HOST_PID": host_pid, "FAKE_PIDS": pids, "FAKE_EXECUTABLE": actual},
            text=True, capture_output=True,
        )
        assert result.returncode == expected_code and result.stdout.splitlines() == expected_actions, result

assert "pgrep" not in source and "pkill" not in source, "cleanup must never match a process pattern"
validation = source.index('HOST_APP="$(validate_host_app "$HOST_APP")"')
assert validation < source.index('test -x "$TAILSCALE"'), "host path must be validated before tooling or launch"
assert source.count('\nHOST_PID="$(resolve_host_listener_pid 7783 "$HOST")"') == 2
assert source.count("LAUNCHER_PID=$!") == 2
launches = source.split("/usr/bin/open -n -W")
assert len(launches) == 3 and all("require_host_port_free 7783" in part for part in launches[:-1])
print("PASS: lock smoke restricts fixture paths, resolves one exact listener, and signals only its host PID")
PYTEST

# Throwaway state, never the real Application Support.
grep -F 'STATE="$ROOT/.build/real-local-lock-typing-smoke"' "$SMOKE" >/dev/null
grep -F 'HOST_HOME="$STATE/host"' "$SMOKE" >/dev/null
grep -F 'CFFIXED_USER_HOME="$HOST_HOME"' "$SMOKE" >/dev/null
grep -F 'CFFIXED_USER_HOME="$CLIENT_HOME"' "$SMOKE" >/dev/null
grep -F 'ARMING_FILE="$HOST_HOME/Library/Application Support/Sensorium/host-screen-arming.json"' "$SMOKE" >/dev/null

# The host is always stopped with a trapped SIGTERM, and the script cannot
# exit silently under set -e.
grep -F 'kill -TERM' "$SMOKE" >/dev/null
grep -E 'trap [a-zA-Z_]+ EXIT' "$SMOKE" >/dev/null
grep -E 'trap [a-zA-Z_]+ ERR' "$SMOKE" >/dev/null

if grep -Ei 'SensoriumCanvasExerciser|screencapture|displayplacer|zip|unzip|sudo|system_profiler|defaults |launchctl' "$SMOKE" >/dev/null; then
  echo 'Lock typing smoke must use the product host and viewer without diagnostic capture, display tools, or privilege escalation.' >&2
  exit 1
fi

sh "$ROOT/Scripts/assert-smoke-isolated.sh" "$SMOKE"

printf 'PASS: real local lock typing smoke harness contract\n'
