#!/usr/bin/env python3
"""Fixture-driven unit test for classify-workspace-focus-blocker.py.

Exercises the three cases the focus-release and workspace-input smokes must
tell apart: a resolved contending-app holder, an unresolved holder, and a
probe log that never hit the condition at all (which must still report as a
genuine FAIL upstream).
"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "classify_workspace_focus_blocker", ROOT / "classify-workspace-focus-blocker.py"
)
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)

RESOLVED_HOLDER = (
    "focus_release_button_down_delivery=delivered\n"
    "workspace_focus_confirmed=false\n"
    "workspace_focus_holder=Terminal\n"
)
UNRESOLVED_HOLDER = (
    "workspace_focus_confirmed=false\n"
    "workspace_focus_holder=unknown\n"
)
MISSING_HOLDER_MARKER = "workspace_focus_confirmed=false\n"
GENUINE_FAILURE = (
    "workspace_focus_confirmed=true\n"
    "focus_release_smoke_failure=the modifier key or the left mouse button was still physically held after focus loss\n"
)

assert classifier.focus_holder(RESOLVED_HOLDER) == "Terminal", classifier.focus_holder(RESOLVED_HOLDER)
assert classifier.focus_holder(UNRESOLVED_HOLDER) == "unknown", classifier.focus_holder(UNRESOLVED_HOLDER)
assert classifier.focus_holder(MISSING_HOLDER_MARKER) is None
assert classifier.focus_holder(GENUINE_FAILURE) is None

resolved_reason = classifier.blocked_reason(RESOLVED_HOLDER)
assert resolved_reason.startswith("Terminal held keyboard focus on this machine"), resolved_reason
assert "leave this machine alone" in resolved_reason, resolved_reason

unresolved_reason = classifier.blocked_reason(UNRESOLVED_HOLDER)
assert unresolved_reason.startswith("another application most likely held keyboard focus"), unresolved_reason
assert "workspace-focus regression" in unresolved_reason, unresolved_reason

missing_holder_reason = classifier.blocked_reason(MISSING_HOLDER_MARKER)
assert missing_holder_reason.startswith("another application most likely held keyboard focus"), missing_holder_reason

# A probe log that never reported the never-frontmost condition at all must
# classify as nothing here, so callers keep reporting it as a genuine FAIL
# rather than misclassifying every failure as a focus contest.
assert classifier.blocked_reason(GENUINE_FAILURE) == ""

# Regardless of what else is in the log, only the last holder marker (the
# one from the failure this call is diagnosing, not a stale one from an
# earlier attempt in the same log) is used.
REPEATED_HOLDER = (
    "workspace_focus_holder=Safari\n"
    "workspace_focus_confirmed=false\n"
    "workspace_focus_holder=Terminal\n"
)
assert classifier.focus_holder(REPEATED_HOLDER) == "Terminal", classifier.focus_holder(REPEATED_HOLDER)

import inspect
assert list(inspect.signature(classifier.focus_holder).parameters) == ["text"]
assert list(inspect.signature(classifier.blocked_reason).parameters) == ["text"]

print("PASS: classify-workspace-focus-blocker fixtures")
