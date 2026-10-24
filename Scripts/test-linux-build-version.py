#!/usr/bin/env python3
"""Prove the RPM's compiler flag reaches the runtime version getter."""
import argparse
import pathlib
import shlex
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=pathlib.Path, default=root / "Sources/CWaylandGlue/glue.c")
args = parser.parse_args()
spec = (root / "Packaging/linux/sensorium.spec.in").read_text()
build = next(line for line in spec.splitlines() if line.startswith("swift build "))
fixture_version = "9.8.7-fixture"
flags = shlex.split(build.replace("%{version}", fixture_version))
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
        assert actual == expected, f"expected {expected}, got {actual}"
        print(f"PASS: runtime build version {actual}")
