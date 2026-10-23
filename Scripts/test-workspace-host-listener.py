#!/usr/bin/env python3
"""Exercise the smoke's actual listener selector with process/listener fixtures."""
from pathlib import Path
import subprocess

source = (Path(__file__).resolve().parent / "run-real-local-workspace-input-smoke.sh").read_text()
start = source.index("resolve_host_listener_pid() {")
end = source.index("\n}\n", start) + 3
function = source[start:end]
expected = "/repo/Artifacts/Sensorium/Sensorium Host.app/Contents/MacOS/SensoriumHost"
for pids, executable, accepted in [
    ("", expected, False),
    ("123\n456", expected, False),
    ("123", "/Applications/Sensorium Host.app/Contents/MacOS/SensoriumHost", False),
    ("123", "/repo/other/SensoriumHost", False),
    ("456", expected, True),
]:
    fixture = function + '''
lsof() { printf '%s\\n' "$FIXTURE_PIDS"; }
ps() { printf '%s\\n' "$FIXTURE_EXECUTABLE"; }
resolve_host_listener_pid 7781 "$EXPECTED_EXECUTABLE"
'''
    result = subprocess.run(["sh", "-c", fixture], env={"PATH": "/usr/bin:/bin", "FIXTURE_PIDS": pids,
        "FIXTURE_EXECUTABLE": executable, "EXPECTED_EXECUTABLE": expected}, text=True, capture_output=True)
    assert (result.returncode == 0) == accepted, (pids, executable, result)
    if accepted:
        assert result.stdout.strip() == "456", result
print("PASS: actual smoke listener selector refuses absent, ambiguous and wrong-executable listeners")

start = source.index("stop_host() {")
end = source.index("\n}\n", start) + 3
stop = source[start:end]
for host_pid, listener_pids, executable, accepted in [
    ("123", "", expected, True),
    ("", "", expected, False),
    ("123", "", "/Applications/Sensorium Host.app/Contents/MacOS/SensoriumHost", False),
    ("", "123", expected, True),
]:
    fixture = function + "\n" + stop + '''
lsof() { printf '%s\\n' "$FIXTURE_PIDS"; }
ps() { printf '%s\\n' "$FIXTURE_EXECUTABLE"; }
kill() { printf 'kill:%s\\n' "$*"; }
wait() { printf 'wait:%s\\n' "$*"; }
HOST_PID="$FIXTURE_HOST_PID"
LAUNCHER_PID=456
stop_host
'''
    result = subprocess.run(["sh", "-c", fixture], env={"PATH": "/usr/bin:/bin", "FIXTURE_PIDS": listener_pids,
        "FIXTURE_EXECUTABLE": executable, "FIXTURE_HOST_PID": host_pid,
        "HOST_APP": "/repo/Artifacts/Sensorium/Sensorium Host.app"}, text=True, capture_output=True)
    assert (result.returncode == 0) == accepted, result
    if accepted:
        assert result.stdout.splitlines() == ["kill:-TERM 123", "wait:456"], result.stdout
    else:
        assert not result.stdout and "FAIL:" in result.stderr, result
print("PASS: teardown validates the exact executable before TERM and waits only after identifying its own host")

start = source.index("require_verification_port_available() {")
end = source.index("\n}\n", start) + 3
vacancy = source[start:end]
for listener_status, accepted in [(0, False), (1, True), (127, False)]:
    fixture = vacancy + '\nlsof() { return "$FIXTURE_STATUS"; }\nrequire_verification_port_available 7781'
    result = subprocess.run(["sh", "-c", fixture], env={"FIXTURE_STATUS": str(listener_status)},
                            text=True, capture_output=True)
    assert (result.returncode == 0) == accepted, result
print("PASS: verification port preflight refuses preexisting listeners and unavailable inspection")

import tempfile
with tempfile.TemporaryDirectory() as directory:
    probe_log = Path(directory) / "probe.log"
    start = source.index("fail_with_diagnosis() {")
    end = source.index("\n}\n", start) + 3
    diagnosis = source[start:end]
    for text, status in [
        ("workspace_text_observation_blocked=yes\n", 3),
        ("local workspace input probe failed: workspaceTextObservationUnavailable\n", 1),
        ("local workspace input probe failed: processExecutableMismatch\n", 1),
    ]:
        probe_log.write_text(text)
        result = subprocess.run(["sh", "-c", diagnosis + '\nfail_with_diagnosis "fixture"'],
            env={"PATH": "/usr/bin:/bin", "PROBE_LOG": str(probe_log)}, text=True, capture_output=True)
        assert result.returncode == status, result
        assert ("BLOCKED:" in result.stderr) == (status == 3), result
print("PASS: AX denial is BLOCKED while missing UI or a changed target remains FAIL")
