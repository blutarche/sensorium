#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
mkdir -p "$ROOT/.build"
CHECK_DIR="$(mktemp -d "$ROOT/.build/viewer-window-maximize.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT HUP INT TERM
python3 - "$ROOT/Sources/SensoriumClient/ClientCanvasWindowController.swift" "$CHECK_DIR/Window.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
start = source.index("        window = NSWindow(")
end = source.index("        // AppKit remembers the frame", start)
setup = source[start:end].replace("window = NSWindow(", "let window = NSWindow(", 1)
setup = setup.replace("        self.title = title\n", "")
Path(sys.argv[2]).write_text('''import AppKit
@MainActor func makeViewerWindow() -> NSWindow {
    let contentRect = NSRect(x: 100, y: 100, width: 640, height: 400)
    let title = "Viewer maximize verification"
    let surfaceView = NSView(frame: contentRect)
    let preset = (logicalWidth: 1920, logicalHeight: 1200)
    _ = preset
''' + setup + '''
    window.isReleasedWhenClosed = false
    return window
}
''')
PY
swiftc "$CHECK_DIR/Window.swift" "$ROOT/Scripts/test-viewer-window-maximize.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
