#!/usr/bin/env python3
"""Classifies packaged sensoriumd host log text for the two independent
user-granted authorizations that gate local viewer/control acceptance:
Accessibility and Screen Recording. Pure text classification only — never
reads TCC state, requests a permission, or touches System Settings.

usage: classify-host-permission-blocker.py <host-log-path>
Prints the BLOCKED reason tail (after "BLOCKED: ") and exits 0 if either
permission is missing. Prints nothing and exits 1 if neither marker is
present in the log.
"""
import sys

ACCESSIBILITY_MARKER = "Accessibility is not granted"
SCREEN_RECORDING_MARKER = "SCStreamErrorDomain Code=-3801"


def missing_permissions(text):
    """Returns the subset of ["Accessibility", "Screen Recording"] whose
    marker text is present in `text`, regardless of whether a probe `enter`
    step later succeeded or failed."""
    missing = []
    if ACCESSIBILITY_MARKER in text:
        missing.append("Accessibility")
    if SCREEN_RECORDING_MARKER in text:
        missing.append("Screen Recording")
    return missing


def blocked_reason(text):
    """Returns the BLOCKED message tail naming exactly the missing
    permission(s), or "" if neither marker is present."""
    missing = missing_permissions(text)
    if not missing:
        return ""
    return (
        "packaged host requires user-granted "
        + " and ".join(missing)
        + " before local viewer/control acceptance can run."
    )


def main(argv):
    if len(argv) != 2:
        print("usage: classify-host-permission-blocker.py <host-log-path>", file=sys.stderr)
        return 2
    try:
        text = open(argv[1], errors="replace").read()
    except OSError:
        text = ""
    reason = blocked_reason(text)
    if not reason:
        return 1
    print(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
