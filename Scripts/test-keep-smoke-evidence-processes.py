#!/usr/bin/env python3
"""Exercise the evidence helper's actual process predicate without running ps."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = (root / ".claude/skills/verify-sensorium/scripts/keep-smoke-evidence.sh").read_text()
predicate = source.split("<<'PYPROCESSES'\n", 1)[1].split("\nPYPROCESSES", 1)[0]
namespace = {"__name__": "fixture"}
exec(compile(predicate, "keep-smoke-evidence-process-predicate", "exec"), namespace)
select = namespace["repo_product_processes"]
fixture_root = Path("/private/tmp/sensorium-process-fixture")
repo = str(fixture_root)
lookups = []
def cwd(pid):
    lookups.append(pid)
    return {"5": repo, "6": "/private/tmp/other-project", "14": repo, "15": repo}.get(pid)

rows = f"""1 00:10 /usr/bin/git --git-dir {repo}/.git fetch --tags
2 00:10 /bin/sh {repo}/.build/debug/SensoriumViewerProbe
3 00:10 /usr/bin/swiftc {repo}/Sources/Sensorium/main.swift
4 00:10 {repo}/.build/debug/sensoriumd
5 00:10 .build/release/SensoriumLocalWorkspaceInputProbe
6 00:10 .build/release/SensoriumLocalHostScreenProbe
7 00:10 /Applications/Sensorium Host.app/Contents/MacOS/SensoriumHost
8 00:10 {repo}/Artifacts/Sensorium/Sensorium Host.app/Contents/MacOS/SensoriumHost
9 00:10 {repo}/Artifacts/Sensorium/Sensorium.app/Contents/MacOS/Sensorium
10 00:10 {repo}/.build/debug/SensoriumClientTestRunner
11 00:10 {repo}/Sources/sensoriumd
12 00:10 /private/tmp/sensorium-process-fixture-other/.build/debug/sensoriumd
14 00:10 Artifacts/Sensorium/Sensorium.app/Contents/MacOS/Sensorium
15 00:10 ./.build/debug/SensoriumViewerProbe
"""
actual = select(rows, fixture_root, cwd)
assert [line.split()[0] for line in actual] == ["4", "5", "8", "9", "14", "15"], actual
assert lookups == ["5", "6", "14", "15"], lookups
assert select(f"13 00:01 .build/debug/sensoriumd", fixture_root, lambda _: None) == []
# The former command-line grep reported background Git commands as live apps.
old_match = [row for row in rows.splitlines() if repo + "/" in row and "sensorium" in row.lower()]
assert any(row.startswith("1 ") for row in old_match)
assert not any(row.startswith("1 ") for row in actual)
print("PASS: evidence process predicate finds only repository host/viewer/probe executables, including relative build paths")
