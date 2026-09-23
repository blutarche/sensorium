#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parent.parent
readme = (root / "README.md").read_text()
install = (root / "docs" / "install.md").read_text()

required_readme = [
    "## Status",
    "pinned-identity QUIC",
    "Fedora",
]
required_install = [
    "Show pairing code",
    "Enter address manually",
    "## Linux",
]
for text in required_readme:
    assert text in readme, f"README missing: {text}"
for text in required_install:
    assert text in install, f"install guide missing: {text}"

forbidden_readme = [
    "never run end to end",
    "**None of it has ever run.**",
    "The control transport is TCP over the tailnet, not QUIC.",
    "Linux support is planned.",
]
for forbidden in forbidden_readme:
    assert forbidden not in readme, f"README retains stale statement: {forbidden}"

forbidden_install = [
    "Nothing here has been executed by this repository.",
    "This has never been run end to end.",
    "Start Pairing.command",
    "Start Sensorium Host.command",
    "Enter Sensorium.command",
    "Request Host Permissions.command",
    "Linux support is planned.",
]
for forbidden in forbidden_install:
    assert forbidden not in install, f"install guide retains stale statement: {forbidden}"

print("PASS: documentation states the verified local and pending cross-machine boundaries")
