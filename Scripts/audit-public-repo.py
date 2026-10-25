#!/usr/bin/env python3
"""Fail safely if public-bound repository candidates contain sensitive material.

The audit prints only paths and rule categories; it never echoes matching content.
Use it before staging or publishing.  It checks tracked files plus nonignored
untracked files so accidental additions are caught early.

A maintainer can also keep a list of private terms (machine names, display
models, addresses) that this public script cannot carry itself. The list is
`info/private-terms` inside the git common directory, so it is never tracked,
committed or pushed, and linked worktrees share it. One term per line; blank
lines and lines starting with `#` are ignored. Each term is matched as a
case-insensitive literal against every candidate path, every candidate file
(binary files included, no size cap), and, when the branch has an upstream,
the message and patch of every commit not yet on it. A missing file means no
check.
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


def git_output(*args: str) -> bytes | None:
    """Raw stdout of a git command run in ROOT, or None if it fails."""
    result = subprocess.run(
        ["git", *args], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    return result.stdout if result.returncode == 0 else None


def private_terms() -> list[bytes]:
    """Lowercased terms from the git directory's `info/private-terms`, if any."""
    common = git_output("rev-parse", "--git-common-dir")
    if common is None:
        return []
    location = ROOT / common.decode("utf-8", "surrogateescape").strip() / "info" / "private-terms"
    try:
        text = location.read_bytes().decode("utf-8-sig", "replace")
    except OSError:
        return []
    stripped = (line.strip() for line in text.splitlines())
    return [line.encode("utf-8").lower() for line in stripped if line and not line.startswith("#")]


def has_private_term(data: bytes, terms: list[bytes]) -> bool:
    lowered = data.lower()
    return any(term in lowered for term in terms)


def unpushed_commits() -> list[tuple[str, str]]:
    """(full, abbreviated) hashes of the commits not yet on the upstream branch."""
    if git_output("rev-parse", "--abbrev-ref", "@{upstream}") is None:
        return []
    listing = git_output("log", "--format=%H %h", "@{upstream}..HEAD")
    if listing is None:
        return []
    pairs = [line.split() for line in listing.decode("ascii", "replace").splitlines()]
    return [(pair[0], pair[1]) for pair in pairs]


def commit_text(full: str) -> bytes | None:
    """A commit's message and the lines its patch adds; binary files are
    diffed as text and a merge shows only what it changed against its
    parents. Context and removed lines are left out: a term the upstream
    already carries is no new leak when a commit only shows or removes it."""
    message = git_output("log", "-1", "--format=%B", full)
    patch = git_output(
        "log", "-1", "-p", "--cc", "--text", "--no-ext-diff", "--no-textconv", "--format=", full
    )
    if message is None or patch is None:
        return None
    # A merge's combined diff marks an added line with "+" in any of its
    # leading parent columns.
    added = [
        line for line in patch.splitlines()
        if line.startswith(b"+") or line.startswith(b" +")
    ]
    return message + b"\n".join(added)


def main() -> int:
    findings: list[tuple[str, str]] = []
    terms = private_terms()
    for relative in candidate_paths():
        for category, pattern in PATH_RULES:
            if pattern.search(relative):
                findings.append((relative, category))

        path = ROOT / relative
        try:
            readable = path.is_file()
            size = path.stat().st_size if readable else 0
            # Only the private-term check reads past the size cap.
            raw = path.read_bytes() if readable and (terms or size <= MAX_BYTES) else b""
        except OSError:
            readable, size, raw = False, 0, b""
        if terms and (
            has_private_term(relative.encode("utf-8", "surrogateescape"), terms)
            or has_private_term(raw, terms)
        ):
            findings.append((relative, "private term"))
        if not readable or size > MAX_BYTES or b"\0" in raw:
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
            if relative == "Sources/SensoriumViewerProbe/RenderGtkVerb.swift" and category == "exact private or tailnet address":
                # GTK render fixture addresses, not a real machine on any
                # tailnet.
                continue
            if pattern.search(text):
                findings.append((relative, category))

    if terms:
        for full, short in unpushed_commits():
            text_of_commit = commit_text(full)
            if text_of_commit is not None and has_private_term(text_of_commit, terms):
                findings.append((f"commit {short}", "private term"))

    if findings:
        print("FAIL: public-repository audit found sensitive candidates (content redacted):")
        for relative, category in findings:
            print(f"  {relative}: {category}")
        return 1

    print("PASS: public-repository audit found no sensitive tracked or unignored candidates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
