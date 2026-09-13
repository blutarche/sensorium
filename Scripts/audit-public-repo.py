#!/usr/bin/env python3
"""Fail safely if public-bound repository candidates contain sensitive material.

The audit prints only paths and rule categories; it never echoes matching content.
Use it before staging or publishing.  It checks tracked files plus nonignored
untracked files so accidental additions are caught early.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 2_000_000

PATH_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("credential-or-identity filename", re.compile(
        r"(?:^|/)(?:\.env(?:\.|$)|id_(?:rsa|ecdsa|ed25519)$)|"
        r"\.(?:pem|key|p8|p12|pfx|cer|der|mobileprovision|identity|pairing|certificate|keychain)$",
        re.IGNORECASE,
    )),
    ("generated private artifact", re.compile(
        r"(?:^|/)(?:Artifacts|SensoriumLocal|\.sensorium|__pycache__)(?:/|$)|"
        r"\.(?:pyc|pyo|recording|mov|mp4|hevc|h264|trace|log)$",
        re.IGNORECASE,
    )),
)

CONTENT_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private key material", re.compile(r"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")),
    ("cloud access key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{12,}\b")),
    ("Tailscale auth key", re.compile(r"\btskey-[A-Za-z0-9_-]{12,}\b")),
    # A secret assignment has a literal on its right-hand side. The negative
    # lookahead excludes the shapes that are references instead -- an
    # identifier or dotted path followed by `)`, `,`, `;`, `(`, `else`, `?`,
    # or an `as` cast -- and a bare parameter label with no name at all. A
    # quoted, numeric, hyphenated, or end-of-line value is never excluded.
    ("inline secret assignment", re.compile(
        r"\b(?:password|passwd|secret|token|api[_-]?key)(?:_key|_token)?['\"]?\s*[:=]\s*"
        r"(?![A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\s*(?:[(),;?]|else\b|as\b[?!]?)"
        r"|\s*(?:[)?]|else\b|as\b[?!]?))"
        r"['\"]?[^\s'\"]{8,}",
        re.IGNORECASE,
    )),
    ("personal home path", re.compile(r"/Users/[^/\s'\"]+")),
    # CIDR ranges such as 100.64.0.0/10 remain valid documentation; exact
    # machine addresses do not belong in a future public repository.
    ("exact private or tailnet address", re.compile(
        r"\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}(?!/)|"
        r"\b192\.168\.\d{1,3}\.\d{1,3}(?!/)|"
        r"\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}(?!/)|"
        r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}(?!/)|"
        r"\bfd7a:115c:a1e0(?::[0-9a-f]{1,4}){1,5}\b(?!/)",
    )),
)


def git_lines(*args: str) -> list[str]:
    result = subprocess.run(
        ["git", *args], cwd=ROOT, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    return [item for item in result.stdout.decode("utf-8", "surrogateescape").split("\0") if item]


def candidate_paths() -> list[str]:
    tracked = git_lines("ls-files", "-z")
    untracked = git_lines("ls-files", "--others", "--exclude-standard", "-z")
    return sorted(set(tracked + untracked))


def main() -> int:
    findings: list[tuple[str, str]] = []
    for relative in candidate_paths():
        for category, pattern in PATH_RULES:
            if pattern.search(relative):
                findings.append((relative, category))

        path = ROOT / relative
        try:
            if not path.is_file() or path.stat().st_size > MAX_BYTES:
                continue
            raw = path.read_bytes()
        except OSError:
            continue
        if b"\0" in raw:
            continue
        text = raw.decode("utf-8", "replace")
        for category, pattern in CONTENT_RULES:
            if relative == "Scripts/audit-public-repo.py" and category in {"personal home path", "exact private or tailnet address"}:
                continue
            if relative == "Scripts/test-audit-public-repo.py" and category == "inline secret assignment":
                # Its own true-positive fixtures would flag it.
                continue
            if "TestRunner/" in relative and category == "exact private or tailnet address":
                continue
            if relative == "Scripts/render-ui-previews.swift" and category == "exact private or tailnet address":
                # Picker-preview fixture addresses, not a real machine on
                # any tailnet.
                continue
            if pattern.search(text):
                findings.append((relative, category))

    if findings:
        print("FAIL: public-repository audit found sensitive candidates (content redacted):")
        for relative, category in findings:
            print(f"  {relative}: {category}")
        return 1

    print("PASS: public-repository audit found no sensitive tracked or unignored candidates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
