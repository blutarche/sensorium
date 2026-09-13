#!/bin/sh
# Clipboard sharing must be reachable from the GUI apps, which launch with no
# arguments: neither entry point may gate `ClipboardSyncSession` behind a CLI
# flag, and both must default it through the one shared constant.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VIEWER="$ROOT/Sources/Sensorium/main.swift"
HOST="$ROOT/Sources/sensoriumd/main.swift"

for file in "$VIEWER" "$HOST"; do
  if grep -qF 'clipboard-sync' "$file"; then
    printf '%s still gates clipboard sync behind a --clipboard-sync flag\n' "$file" >&2
    exit 1
  fi
  if grep -qF 'syncClipboard' "$file"; then
    printf '%s still threads a syncClipboard parameter\n' "$file" >&2
    exit 1
  fi
  if ! grep -qF 'ClipboardSyncEngine.sharingEnabledByDefault' "$file"; then
    printf '%s does not default clipboard sharing from ClipboardSyncEngine.sharingEnabledByDefault\n' "$file" >&2
    exit 1
  fi
done

printf 'PASS: clipboard sharing is unconditional in both GUI entry points and defaults from ClipboardSyncEngine.sharingEnabledByDefault\n'
