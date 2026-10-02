#!/bin/sh
# Shared contract check for the real-machine smokes: every launch that points a
# process at the throwaway host or client home must also set CFFIXED_USER_HOME
# (`HOME` alone does not move Foundation's application-support directory), and
# no smoke may bind port 7777, the installed host's port.
# Usage: assert-smoke-isolated.sh <smoke-script>
set -eu

SMOKE="$1"

unisolated="$(grep -E '(^|[ ])HOME="\$(HOST|CLIENT)_HOME"' "$SMOKE" | grep -vF 'CFFIXED_USER_HOME=' || true)"
if [ -n "$unisolated" ]; then
  echo "$SMOKE sets HOME without CFFIXED_USER_HOME on:" >&2
  echo "$unisolated" >&2
  exit 1
fi

if grep -F '7777' "$SMOKE" >/dev/null; then
  echo "$SMOKE uses port 7777, which belongs to the installed host." >&2
  exit 1
fi
