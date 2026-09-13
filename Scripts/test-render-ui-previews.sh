#!/bin/sh
# Contract test for the UI preview renderer's own output location.
#
# The renderer is not run here: it needs a built package and draws every window
# in both apps. What is checked is where it writes when nobody tells it where,
# because a default outside this repository scatters PNGs onto whichever
# machine happens to run it.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RENDERER="$ROOT/Scripts/render-ui-previews.swift"

require() {
  if ! grep -F "$1" "$2" >/dev/null; then
    printf 'render-ui-previews.swift: expected to find %s\n' "$1" >&2
    exit 1
  fi
}

[ -f "$RENDERER" ]

# The default lands under the repository's own ignored Artifacts directory.
require 'Artifacts/ui-previews' "$RENDERER"
require 'Artifacts/' "$ROOT/.gitignore"

# An explicit output directory is still honoured.
require 'arguments.first' "$RENDERER"

# And no absolute path outside the repository is written into the file at all.
if grep -nE '"/(private/)?(tmp|var|Users)/' "$RENDERER" >&2; then
  echo 'render-ui-previews.swift must not hard-code an absolute path outside this repository' >&2
  exit 1
fi

printf 'PASS: UI preview renderer output location contract\n'
