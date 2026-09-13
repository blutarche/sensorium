#!/usr/bin/env python3
"""Fixture-driven unit test for check-display-active.py.

Exercises the two display_inventory.swift snapshot shapes the
real-local-*.sh preflight must tell apart: a screen that is asleep or
locked (empty "active" list) and a normal awake, unlocked screen (non-empty
"active" list). No real display or host process required.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "check_display_active", ROOT / "check-display-active.py"
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def record(id, builtin=False):
    return {
        "id": id,
        "width": 1728,
        "height": 1117,
        "modeWidth": 1728,
        "modeHeight": 1117,
        "modePixelWidth": 1728,
        "modePixelHeight": 1117,
        "boundsX": 0.0,
        "boundsY": 0.0,
        "boundsWidth": 1728.0,
        "boundsHeight": 1117.0,
        "online": True,
        "builtin": builtin,
        "mirroredDisplayID": 0,
    }


BUILTIN = record(1, builtin=True)

# Screen asleep or session locked: CGGetActiveDisplayList returns zero
# active displays even though the display is still online.
asleep_or_locked = {"active": [], "online": [BUILTIN]}
assert checker.active_count(asleep_or_locked) == 0
reason = checker.blocked_reason(asleep_or_locked)
assert reason != "", "expected a BLOCKED reason when no display is active"
assert "wake the display" in reason, reason
assert "unlock the screen" in reason, reason

# Screen awake and unlocked: at least one active display.
awake = {"active": [BUILTIN], "online": [BUILTIN]}
assert checker.active_count(awake) == 1
assert checker.blocked_reason(awake) == ""

# End-to-end through main(): the asleep/locked case must exit 3 with a
# "BLOCKED: " line on stderr naming the remedy; the awake case must exit 0
# with nothing printed.
with tempfile.TemporaryDirectory() as tmp:
    asleep_path = Path(tmp) / "asleep.json"
    asleep_path.write_text(json.dumps(asleep_or_locked))
    blocked_result = subprocess.run(
        [sys.executable, str(ROOT / "check-display-active.py"), str(asleep_path)],
        capture_output=True, text=True,
    )
    assert blocked_result.returncode == 3, blocked_result
    assert blocked_result.stderr.startswith("BLOCKED: "), blocked_result.stderr
    assert "wake the display" in blocked_result.stderr, blocked_result.stderr
    assert "unlock the screen" in blocked_result.stderr, blocked_result.stderr
    assert blocked_result.stdout == "", blocked_result.stdout

    awake_path = Path(tmp) / "awake.json"
    awake_path.write_text(json.dumps(awake))
    passthrough_result = subprocess.run(
        [sys.executable, str(ROOT / "check-display-active.py"), str(awake_path)],
        capture_output=True, text=True,
    )
    assert passthrough_result.returncode == 0, passthrough_result
    assert passthrough_result.stderr == "", passthrough_result.stderr

print("PASS: check-display-active fixtures")
