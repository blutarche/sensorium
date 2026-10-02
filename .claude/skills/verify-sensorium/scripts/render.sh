#!/bin/sh
# Renders every production AppKit view of both apps to PNG, offscreen, into a
# fresh evidence directory, then checks that the named files exist and are
# real pictures.
#
#   .claude/skills/verify-sensorium/scripts/render.sh <label> [expected.png ...]
#   .claude/skills/verify-sensorium/scripts/render.sh --check <evidence-dir> [expected.png ...]
#
# Writes Artifacts/verify/<UTC timestamp>-<label>/previews/ (PNGs + index.txt)
# and render.log beside it. Prints the evidence directory on its last line.
# --check skips the render and checks files in an existing evidence directory.
# Needs no window, display, permission or socket. Run it unsandboxed:
# SwiftPM cannot build inside a nested sandbox.
set -eu

[ $# -ge 1 ] || { echo "usage: render.sh <label> [expected.png ...] | --check <evidence-dir> [expected.png ...]" >&2; exit 2; }
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
cd "$ROOT"
if [ "$1" = "--check" ]; then
  [ $# -ge 2 ] && [ -f "$2/previews/index.txt" ] || { echo "no previews/index.txt under ${2:-<missing>}" >&2; exit 2; }
  EVIDENCE="$(CDPATH= cd -- "$2" && pwd)"; shift 2
  echo "checking $(sed -n 1p "$EVIDENCE/commit.txt" 2>/dev/null | cut -c1-12) render; HEAD is $(git rev-parse --short=12 HEAD)"
else
  label="$1"; shift
  EVIDENCE="$ROOT/Artifacts/verify/$(date -u +%Y%m%dT%H%M%SZ)-$label"
  mkdir -p "$EVIDENCE/previews"
  git rev-parse HEAD > "$EVIDENCE/commit.txt"
  git diff --stat >> "$EVIDENCE/commit.txt"

  status=0
  swift Scripts/render-ui-previews.swift "$EVIDENCE/previews" > "$EVIDENCE/render.log" 2>&1 || status=$?
  echo "renderer exit=$status" | tee -a "$EVIDENCE/render.log"
  [ "$status" -eq 0 ] || { tail -20 "$EVIDENCE/render.log"; echo "$EVIDENCE"; exit 1; }
  echo "$(ls "$EVIDENCE/previews" | grep -c '\.png$') PNGs"
fi

missing=0
for file in "$@"; do
  # index.txt columns: FILE BYTES PIXELS NON-BG COLOURS STATE
  row="$(awk -v f="$file" '$1 == f' "$EVIDENCE/previews/index.txt")"
  if [ ! -s "$EVIDENCE/previews/$file" ] || [ -z "$row" ]; then
    echo "MISSING: $file"
    missing=1
    continue
  fi
  nonbg="$(printf '%s' "$row" | awk '{print $4}')"
  if awk -v n="$nonbg" 'BEGIN { exit !(n > 0) }'; then
    echo "ok: $file  non-bg=$nonbg"
  else
    echo "BLANK: $file  non-bg=$nonbg"
    missing=1
  fi
done > "$EVIDENCE/.expected.this-run"
cat "$EVIDENCE/.expected.this-run"
cat "$EVIDENCE/.expected.this-run" >> "$EVIDENCE/expected.txt"
grep -q '^MISSING\|^BLANK' "$EVIDENCE/.expected.this-run" && missing=1
rm -f "$EVIDENCE/.expected.this-run"
echo "$EVIDENCE"
exit "$missing"
