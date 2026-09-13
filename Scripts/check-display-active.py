#!/usr/bin/env python3
"""Preflight gate for the real-local-*.sh smokes: refuses to start a session
against a machine whose screen is asleep, instead of letting pairing/serving
run for minutes and then fail with a cryptic probe or host-log timeout.
CGGetActiveDisplayList reports zero active displays while the display is
asleep, even though it stays online. Pure JSON classification of a
display_inventory.swift snapshot only — never queries a display itself.

usage: check-display-active.py <display-inventory.json>
Reads a display_inventory.swift snapshot. If its "active" list is empty,
prints "BLOCKED: ..." to stderr and exits 3. Otherwise exits 0 silently.
"""
import json
import sys


def active_count(inventory):
    """Returns the number of active displays in a display_inventory.swift
    JSON payload."""
    return len(inventory["active"])


def blocked_reason(inventory):
    """Returns the BLOCKED message tail, or "" if at least one display is
    active."""
    if active_count(inventory) > 0:
        return ""
    return (
        "no active displays (screen is asleep or the session is locked); "
        "wake the display and unlock the screen, then re-run."
    )


def main(argv):
    if len(argv) != 2:
        print("usage: check-display-active.py <display-inventory.json>", file=sys.stderr)
        return 2
    with open(argv[1]) as handle:
        inventory = json.load(handle)
    reason = blocked_reason(inventory)
    if not reason:
        return 0
    print("BLOCKED: " + reason, file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
