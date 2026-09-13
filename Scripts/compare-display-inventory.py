#!/usr/bin/env python3
"""Diffs two display-inventory snapshots captured by display_inventory.swift,
one taken before a session's host starts and one taken after its teardown
completes. Requires the exact same set of online display IDs and the exact
same mode (logical and native pixel size) for every surviving ID, catching
a leaked canvas at any size, and a changed mode on a pre-existing display.
Pure JSON comparison only — never queries a display itself.

usage: compare-display-inventory.py <pre-inventory.json> <post-inventory.json>
Prints "display_inventory_unchanged=yes" and exits 0 if the two snapshots'
online display lists match exactly. Otherwise prints
"display_inventory_unchanged=no" to stdout, prints one
"display_inventory_diff=..." line per difference to stderr naming the
specific display ID and what changed, and exits 1.
"""
import json
import sys


def _mode(record):
    return (
        record["modeWidth"],
        record["modeHeight"],
        record["modePixelWidth"],
        record["modePixelHeight"],
    )


def _describe_mode(record):
    return "{}x{} (pixel {}x{})".format(
        record["modeWidth"], record["modeHeight"],
        record["modePixelWidth"], record["modePixelHeight"],
    )


def online_by_id(inventory):
    """Returns the "online" records of a display_inventory.swift JSON
    payload, keyed by display ID."""
    return {record["id"]: record for record in inventory["online"]}


def diff_inventories(pre, post):
    """Returns a list of human-readable difference strings, each naming a
    specific display ID and what changed, comparing the "online" records of
    two display_inventory.swift snapshots. Empty if the snapshots match."""
    pre_by_id = online_by_id(pre)
    post_by_id = online_by_id(post)

    differences = []
    for display_id in sorted(set(post_by_id) - set(pre_by_id)):
        differences.append(
            "display {} appeared after teardown at {}".format(
                display_id, _describe_mode(post_by_id[display_id])
            )
        )
    for display_id in sorted(set(pre_by_id) - set(post_by_id)):
        differences.append(
            "display {} vanished after teardown (was {})".format(
                display_id, _describe_mode(pre_by_id[display_id])
            )
        )
    for display_id in sorted(set(pre_by_id) & set(post_by_id)):
        before = pre_by_id[display_id]
        after = post_by_id[display_id]
        if _mode(before) != _mode(after):
            differences.append(
                "display {} mode changed from {} to {}".format(
                    display_id, _describe_mode(before), _describe_mode(after)
                )
            )
    return differences


def main(argv):
    if len(argv) != 3:
        print("usage: compare-display-inventory.py <pre-inventory.json> <post-inventory.json>", file=sys.stderr)
        return 2

    with open(argv[1], encoding="utf-8") as handle:
        pre = json.load(handle)
    with open(argv[2], encoding="utf-8") as handle:
        post = json.load(handle)

    differences = diff_inventories(pre, post)
    if differences:
        print("display_inventory_unchanged=no")
        for difference in differences:
            print("display_inventory_diff=" + difference, file=sys.stderr)
        return 1

    print("display_inventory_unchanged=yes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
