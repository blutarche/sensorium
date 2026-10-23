#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sensorium-host-target.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM
python3 - "$ROOT/Sources/SensoriumLocalWorkspaceInputProbe/main.swift" "$CHECK_DIR/HostWorkspaceActivationTarget.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text("import Foundation\n" + source[source.index("enum WorkspaceTextObservation {"):])
PYTHON
swiftc "$CHECK_DIR/HostWorkspaceActivationTarget.swift" \
  "$ROOT/Scripts/test-workspace-host-target.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
python3 "$ROOT/Scripts/test-workspace-host-listener.py"
