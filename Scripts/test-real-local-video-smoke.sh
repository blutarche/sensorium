#!/bin/sh
# Contract test for the real local capture/decode smoke harness.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE="$ROOT/Scripts/run-real-local-video-smoke.sh"

[ -x "$SMOKE" ]
grep -F 'SensoriumLocalWorkspaceInputProbe' "$SMOKE" >/dev/null
grep -F '"$PROBE" enter-video "$ADDRESS" "$PORT"' "$SMOKE" >/dev/null
grep -F 'video_probe_disconnected=yes' "$SMOKE" >/dev/null
grep -F 'wait_for_canvas_cleanup || fail_with_diagnosis' "$SMOKE" >/dev/null
grep -F 'decoded > 0 and presented > 0' "$SMOKE" >/dev/null
grep -F 'tcp-local-verification' "$SMOKE" >/dev/null
grep -F 'workspace started on session canvas' "$SMOKE" >/dev/null
grep -F 'workspace_frame_presented=yes' "$SMOKE" >/dev/null
grep -F 'compare-display-inventory.py' "$SMOKE" >/dev/null
grep -F 'display-inventory-pre.json' "$SMOKE" >/dev/null
grep -F 'display-inventory-post.json' "$SMOKE" >/dev/null

# A screen that is asleep or a session that is locked must fail fast, before
# pairing or serving even start, with a BLOCKED line naming the remedy.
grep -F 'check-display-active.py' "$SMOKE" >/dev/null
grep -F 'check-display-active.py "$STATE/display-inventory-pre.json" || exit 3' "$SMOKE" >/dev/null
if grep -Ei 'SensoriumCanvasExerciser|zip|unzip|sudo|system_profiler' "$SMOKE" >/dev/null; then
  echo 'Local video smoke must use the product workspace, not an exerciser, archive, privilege escalation, or System Profiler.' >&2
  exit 1
fi

# Exercise the real failure function without launching either app.
python3 - "$ROOT" "$SMOKE" <<'PYTEST'
from pathlib import Path
import subprocess
import sys
import tempfile

root, smoke = map(Path, sys.argv[1:])
source = smoke.read_text()
start = source.index("fail_with_diagnosis() {")
function = source[start:source.index("\n}\n", start) + 3]
fixture_root = root / ".build"
fixture_root.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(dir=fixture_root) as directory:
    host_log = Path(directory) / "host.log"
    cases = [
        ("SCStreamErrorDomain Code=-3801", 3, "BLOCKED:", "Screen Recording"),
        ("Accessibility is not granted", 3, "BLOCKED:", "Accessibility"),
        ("SCStreamErrorDomain Code=-3801\nAccessibility is not granted", 3, "BLOCKED:", "Accessibility and Screen Recording"),
        ("capture failed for another reason", 1, "FAIL:", "fixture failure"),
    ]
    for text, code, label, reason in cases:
        host_log.write_text(text)
        result = subprocess.run(
            ["sh", "-c", 'ROOT="$1"; HOST_LOG="$2"; CLIENT_LOG="$3"\n' + function
             + '\nfail_with_diagnosis "fixture failure"', "diagnostic-fixture", str(root), str(host_log), str(Path(directory) / "client.log")],
            text=True, capture_output=True,
        )
        assert result.returncode == code, (code, result.returncode, result.stderr)
        assert label in result.stderr and reason in result.stderr, result.stderr
def definition(name):
    start = source.index(name + "() {")
    return source[start:source.index("\n}\n", start) + 3]

with tempfile.TemporaryDirectory(dir=fixture_root) as directory:
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
                         (escaped, False), (executable_escape, False)):
        result = subprocess.run(
            ["sh", "-c", 'ROOT="$1"\n' + definition("validate_host_app") + '\nvalidate_host_app "$2"',
             "path-fixture", str(repository), str(app)], text=True, capture_output=True,
        )
        assert (result.returncode == 0) == allowed, (app, result)

    stubs = '''lsof() { printf '%s\\n' "$FAKE_PIDS"; }
ps() { printf '%s\\n' "$FAKE_EXECUTABLE"; }
'''
    import os
    for pids, executable, allowed in (("123", str(signed), True), ("", str(signed), False),
                                       ("123\n456", str(signed), False), ("123", str(outside), False)):
        result = subprocess.run(
            ["sh", "-c", stubs + definition("resolve_host_listener_pid") + '\nresolve_host_listener_pid 7782 "$1"',
             "listener-fixture", str(signed)],
            env={**os.environ, "FAKE_PIDS": pids, "FAKE_EXECUTABLE": executable}, text=True, capture_output=True,
        )
        assert (result.returncode == 0) == allowed, (pids, executable, result)
        if allowed:
            assert result.stdout.strip() == "123", result.stdout

    for actual, expected_signals in ((str(signed), ["-TERM 123", "wait 456"]),
                                     (str(outside), [])):
        result = subprocess.run(
            ["sh", "-c", stubs + '''kill() { printf '%s\\n' "$*"; }
wait() { printf 'wait %s\\n' "$1"; }
HOST_PID=123
LAUNCHER_PID=456
HOST="$1"
''' + definition("stop_host") + '\nstop_host', "stop-fixture", str(signed)],
            env={**os.environ, "FAKE_EXECUTABLE": actual}, text=True, capture_output=True,
        )
        assert (result.returncode == 0) == bool(expected_signals), result
        assert result.stdout.splitlines() == expected_signals, result

    for pids, allowed in (("123", True), ("", False)):
        result = subprocess.run(
            ["sh", "-c", stubs + '''kill() { printf '%s\\n' "$*"; }
wait() { printf 'wait %s\\n' "$1"; }
HOST_PID=""
LAUNCHER_PID=456
PORT=7782
HOST="$1"
''' + definition("resolve_host_listener_pid") + definition("stop_host") + '\nstop_host',
             "unresolved-fixture", str(signed)],
            env={**os.environ, "FAKE_PIDS": pids, "FAKE_EXECUTABLE": str(signed)}, text=True, capture_output=True,
        )
        assert (result.returncode == 0) == allowed, result
        assert result.stdout.splitlines() == (["-TERM 123", "wait 456"] if allowed else []), result
print("PASS: video smoke restricts fixture paths, signals only its exact host, and waits for its launcher")
print("PASS: video smoke distinguishes permission blockers from failures")
PYTEST

# Throwaway state must never alias the real Application Support or the installed
# host's port.
sh "$ROOT/Scripts/assert-smoke-isolated.sh" "$SMOKE"

printf 'PASS: real local video smoke harness contract\n'
