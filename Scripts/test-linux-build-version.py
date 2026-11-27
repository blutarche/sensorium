#!/usr/bin/env python3
"""Prove each RPM's compiler flag reaches the runtime version getter."""
import argparse
import pathlib
import shlex
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=pathlib.Path, default=root / "Sources/CWaylandGlue/glue.c")
args = parser.parse_args()
fixture_version = "9.8.7-fixture"
# The viewer and the host each read their version through the same getter,
# and each updater compares it with the release it installs.
for spec_name in ("sensorium.spec.in", "sensorium-host.spec.in"):
    spec = (root / "Packaging/linux" / spec_name).read_text()
    build = next(line for line in spec.splitlines() if line.startswith("swift build "))
    flags = shlex.split(build.replace("%{version}", fixture_version))
    assert "-Xcc" in flags, f"{spec_name} builds with no version stamp: {build}"
    macro = flags[flags.index("-Xcc") + 1]
    with tempfile.TemporaryDirectory(prefix="sensorium-version-") as scratch:
        scratch = pathlib.Path(scratch)
        main = scratch / "main.c"
        main.write_text('#include <stdio.h>\n#include "sensorium-wayland-glue.h"\nint main(void) { puts(sensorium_build_version()); }\n')
        for expected, extra in [("development", []), (fixture_version, [macro])]:
            binary = scratch / "version"
            subprocess.run([
                "cc", "-U__linux__", "-I", str(root / "Sources/CWaylandGlue/include"),
                *extra, str(args.source), str(main), "-o", str(binary)
            ], check=True)
            actual = subprocess.check_output([str(binary)], text=True).strip()
            assert actual == expected, f"{spec_name}: expected {expected}, got {actual}"
            print(f"PASS: {spec_name} runtime build version {actual}")
