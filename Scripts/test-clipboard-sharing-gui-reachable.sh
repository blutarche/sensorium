#!/bin/sh
# Clipboard sharing must be reachable from the GUI apps, which launch with no
# arguments: neither entry point may gate `ClipboardSyncSession` behind a CLI
# flag. The viewer defaults it through `sharingEnabledByDefault`; the host
# starts each connection through `hostSharingEnabledAtConnect` and follows the
# viewer's choice from there.
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
done

if ! grep -qF 'ClipboardSyncEngine.sharingEnabledByDefault' "$VIEWER"; then
  printf '%s does not default clipboard sharing from ClipboardSyncEngine.sharingEnabledByDefault\n' "$VIEWER" >&2
  exit 1
fi
if ! grep -qF 'ClipboardSyncEngine.hostSharingEnabledAtConnect' "$HOST"; then
  printf '%s does not start clipboard sharing from ClipboardSyncEngine.hostSharingEnabledAtConnect\n' "$HOST" >&2
  exit 1
fi

printf 'PASS: clipboard sharing is unconditional in both GUI entry points, the viewer defaults from sharingEnabledByDefault, and the host starts from hostSharingEnabledAtConnect\n'
