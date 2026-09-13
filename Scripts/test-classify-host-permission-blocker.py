#!/usr/bin/env python3
"""Fixture-driven unit test for classify-host-permission-blocker.py.

Exercises the four permission-marker combinations the workspace-input smoke
harness must tell apart: Accessibility missing only, Screen Recording
missing only, both missing, and neither missing.
"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "classify_host_permission_blocker", ROOT / "classify-host-permission-blocker.py"
)
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)

ACCESSIBILITY_ONLY = "Accessibility is not granted: this host will stream the canvas but refuse remote input.\n"
SCREEN_RECORDING_ONLY = "capture could not start on session canvas 5: SCStreamErrorDomain Code=-3801\n"
BOTH_MISSING = ACCESSIBILITY_ONLY + SCREEN_RECORDING_ONLY
NEITHER_MISSING = "Sensorium host bound; tailnet sources only\nworkspace started on session canvas 5\ncapture started on session canvas 5\n"

assert classifier.missing_permissions(ACCESSIBILITY_ONLY) == ["Accessibility"], \
    classifier.missing_permissions(ACCESSIBILITY_ONLY)
assert classifier.missing_permissions(SCREEN_RECORDING_ONLY) == ["Screen Recording"], \
    classifier.missing_permissions(SCREEN_RECORDING_ONLY)
assert classifier.missing_permissions(BOTH_MISSING) == ["Accessibility", "Screen Recording"], \
    classifier.missing_permissions(BOTH_MISSING)
assert classifier.missing_permissions(NEITHER_MISSING) == [], \
    classifier.missing_permissions(NEITHER_MISSING)

assert classifier.blocked_reason(ACCESSIBILITY_ONLY) == (
    "packaged host requires user-granted Accessibility before local viewer/control acceptance can run."
)
assert classifier.blocked_reason(SCREEN_RECORDING_ONLY) == (
    "packaged host requires user-granted Screen Recording before local viewer/control acceptance can run."
)
assert classifier.blocked_reason(BOTH_MISSING) == (
    "packaged host requires user-granted Accessibility and Screen Recording before local viewer/control acceptance can run."
)
assert classifier.blocked_reason(NEITHER_MISSING) == ""

# Regardless of whether the probe's `enter` step succeeded or failed, the
# classifier only looks at host log text: it takes no argument about enter's
# outcome, so callers cannot accidentally gate detection on it.
import inspect
assert list(inspect.signature(classifier.missing_permissions).parameters) == ["text"]
assert list(inspect.signature(classifier.blocked_reason).parameters) == ["text"]

print("PASS: classify-host-permission-blocker fixtures")
