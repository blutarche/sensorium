#!/usr/bin/env python3
"""Classifies `SensoriumLocalWorkspaceInputProbe` log text for the
workspace-never-came-frontmost condition (`workspace_focus_confirmed=false`),
which is ambiguous between someone actively using this machine and a genuine
workspace-focus regression. `workspace_focus_holder=<name>` is the one piece
of evidence that discriminates the two. Never queries `NSWorkspace` or any
other live state itself.

usage: classify-workspace-focus-blocker.py <probe-log-path>
Prints the BLOCKED reason tail (after "BLOCKED: ") and exits 0 if the probe
reported `workspace_focus_confirmed=false`. Prints nothing and exits 1
otherwise.
"""
import sys

FOCUS_NEVER_CONFIRMED_MARKER = "workspace_focus_confirmed=false"
HOLDER_PREFIX = "workspace_focus_holder="
UNRESOLVED_HOLDERS = ("", "unknown")


def focus_holder(text):
    """Returns the last `workspace_focus_holder=` value in `text`, or None if
    the marker is absent."""
    holder = None
    for line in text.splitlines():
        if line.startswith(HOLDER_PREFIX):
            holder = line[len(HOLDER_PREFIX):]
    return holder


def blocked_reason(text):
    """Returns the BLOCKED message tail for a workspace-never-frontmost
    condition, or "" if `text` does not report one."""
    if FOCUS_NEVER_CONFIRMED_MARKER not in text:
        return ""
    holder = focus_holder(text)
    if holder is not None and holder not in UNRESOLVED_HOLDERS:
        return (
            holder + " held keyboard focus on this machine, so the packaged "
            "host workspace could not come to the front to receive input; "
            "leave this machine alone (do not use it) while the smoke runs, "
            "then re-run."
        )
    return (
        "another application most likely held keyboard focus on this "
        "machine while the smoke ran (macOS refuses to hand a background "
        "app frontmost while someone is using the machine); leave this "
        "machine alone while the smoke runs, then re-run. If nothing was "
        "using this machine, this is a workspace-focus regression instead."
    )


def main(argv):
    if len(argv) != 2:
        print("usage: classify-workspace-focus-blocker.py <probe-log-path>", file=sys.stderr)
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
