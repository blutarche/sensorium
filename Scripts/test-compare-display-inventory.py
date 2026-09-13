#!/usr/bin/env python3
"""Fixture-driven unit test for compare-display-inventory.py.

Exercises the two defects the comparator must catch: a leaked canvas at
any size, and a changed mode on a pre-existing (e.g. physical) display.
Uses only in-memory fixture dictionaries shaped like
display_inventory.swift's JSON output — no real display or host process
required.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "compare_display_inventory", ROOT / "compare-display-inventory.py"
)
comparator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparator)


def record(id, mode_width, mode_height, mode_pixel_width=None, mode_pixel_height=None, builtin=False):
    if mode_pixel_width is None:
        mode_pixel_width = mode_width
    if mode_pixel_height is None:
        mode_pixel_height = mode_height
    return {
        "id": id,
        "width": mode_width,
        "height": mode_height,
        "modeWidth": mode_width,
        "modeHeight": mode_height,
        "modePixelWidth": mode_pixel_width,
        "modePixelHeight": mode_pixel_height,
        "boundsX": 0.0,
        "boundsY": 0.0,
        "boundsWidth": float(mode_width),
        "boundsHeight": float(mode_height),
        "online": True,
        "builtin": builtin,
        "mirroredDisplayID": 0,
    }


BUILTIN = record(1, 1728, 1117, builtin=True)

# Identical snapshots: no session-owned canvas ever appeared, no physical
# display changed. Must be reported as unchanged.
pre_clean = {"active": [BUILTIN], "online": [BUILTIN]}
post_clean = {"active": [BUILTIN], "online": [BUILTIN]}
assert comparator.diff_inventories(pre_clean, post_clean) == []

# A leaked canvas at a size other than 1920x1200 must still be caught.
leaked_canvas = record(99, 2560, 1440)
pre_leak = {"active": [BUILTIN], "online": [BUILTIN]}
post_leak = {"active": [BUILTIN, leaked_canvas], "online": [BUILTIN, leaked_canvas]}
leak_diff = comparator.diff_inventories(pre_leak, post_leak)
assert len(leak_diff) == 1, leak_diff
assert "display 99" in leak_diff[0], leak_diff
assert "appeared" in leak_diff[0], leak_diff
assert "2560x1440" in leak_diff[0], leak_diff

# A physical display whose mode changed during the session — the v1 core
# invariant that a session must never reconfigure a physical display — must
# be caught even though the display's ID never changed.
reconfigured_builtin = record(1, 2560, 1600, builtin=True)
pre_reconfig = {"active": [BUILTIN], "online": [BUILTIN]}
post_reconfig = {"active": [reconfigured_builtin], "online": [reconfigured_builtin]}
reconfig_diff = comparator.diff_inventories(pre_reconfig, post_reconfig)
assert len(reconfig_diff) == 1, reconfig_diff
assert "display 1" in reconfig_diff[0], reconfig_diff
assert "mode changed" in reconfig_diff[0], reconfig_diff
assert "1728x1117" in reconfig_diff[0], reconfig_diff
assert "2560x1600" in reconfig_diff[0], reconfig_diff

# A display that vanished (e.g. a physical display unplugged mid-session)
# must also be named specifically, not folded into a generic message.
pre_vanish = {"active": [BUILTIN, leaked_canvas], "online": [BUILTIN, leaked_canvas]}
post_vanish = {"active": [BUILTIN], "online": [BUILTIN]}
vanish_diff = comparator.diff_inventories(pre_vanish, post_vanish)
assert len(vanish_diff) == 1, vanish_diff
assert "display 99" in vanish_diff[0], vanish_diff
assert "vanished" in vanish_diff[0], vanish_diff

# End-to-end through main(): the leaked-canvas case must exit non-zero and
# report the specific display and mode, never a bare "inventory differs".
with tempfile.TemporaryDirectory() as tmp:
    pre_path = Path(tmp) / "pre.json"
    post_path = Path(tmp) / "post.json"
    pre_path.write_text(json.dumps(pre_leak))
    post_path.write_text(json.dumps(post_leak))
    result = subprocess.run(
        [sys.executable, str(ROOT / "compare-display-inventory.py"), str(pre_path), str(post_path)],
        capture_output=True, text=True,
    )
    assert result.returncode == 1, result
    assert "display_inventory_unchanged=no" in result.stdout, result.stdout
    assert "display 99" in result.stderr, result.stderr
    assert "2560x1440" in result.stderr, result.stderr
    assert "inventory differs" not in result.stderr.lower(), result.stderr

    clean_pre_path = Path(tmp) / "clean-pre.json"
    clean_post_path = Path(tmp) / "clean-post.json"
    clean_pre_path.write_text(json.dumps(pre_clean))
    clean_post_path.write_text(json.dumps(post_clean))
    clean_result = subprocess.run(
        [sys.executable, str(ROOT / "compare-display-inventory.py"), str(clean_pre_path), str(clean_post_path)],
        capture_output=True, text=True,
    )
    assert clean_result.returncode == 0, clean_result
    assert "display_inventory_unchanged=yes" in clean_result.stdout, clean_result.stdout

print("PASS: compare-display-inventory fixtures")
