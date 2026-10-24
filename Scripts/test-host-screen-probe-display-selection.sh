#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-probe-display.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM
python3 - "$ROOT/Sources/SensoriumLocalHostScreenProbe/main.swift" "$CHECK_DIR/Selection.swift" <<'PYEXTRACT'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index("    private static func targetDisplay(")
end = source.index("\n    }", start) + len("\n    }")
body = source[start:end].replace("private static func", "static func", 1)
Path(sys.argv[2]).write_text("@MainActor enum Probe {\n" + body + "\n}\n")
PYEXTRACT
swiftc "$CHECK_DIR/Selection.swift" "$ROOT/Scripts/test-host-screen-probe-display-selection.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
