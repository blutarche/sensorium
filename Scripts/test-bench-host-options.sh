#!/bin/sh
# Compiles the stand-in host's command-line parser and packet log line format
# beside their checks and runs them. The stand-in is an executable target, so no
# test runner can import it; these two sources import only Foundation.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-bench-options.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM
swiftc \
    "$ROOT/Sources/SensoriumBenchHost/BenchHostOptions.swift" \
    "$ROOT/Sources/SensoriumBenchHost/PacketLog.swift" \
    "$ROOT/Scripts/test-bench-host-options.swift" \
    -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
